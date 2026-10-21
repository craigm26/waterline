#!/usr/bin/env python3
"""Pre-stage public data for the Waterline demo sites.

Sites
  rain    17th & Folsom, Mission (combined-sewer ponding)
  coast   Ferry Building / Embarcadero (SHACK15 venue, king tide + Kelvin wave + surge)

Steps (each independent; failures are reported, not fatal)
  tide_datums      CO-OPS datums for 9414290 (STND-based; used to convert flood levels)
  flood_levels     CO-OPS NOS/NWS coastal flood thresholds, converted to ft MLLW
  king_tides       High/low predictions Nov 2026 - Feb 2027, top highs
  kelvin_anomaly   Observed minus predicted water level: Oct 2026 so far vs Oct 2025 baseline
                   and the 1982-83 / 1997-98 El Nino winters (the Kelvin-wave + storm signal)
  replay_tide      Observed 6-min water level for the replay window
  atlas14          NOAA Atlas 14 precipitation frequency (PDS, depth, in) at 17th & Folsom
  rain_daily       GHCN-Daily PRCP, SF Downtown (USW00023272), replay window
  rain_hourly      IEM ASOS hourly precip at SFO (temporal shape only; DERIVED for downtown)
  sf311_flooding   SF 311 "Sewer Issues / Flooding" reports near each site, replay window
  sfpuc_flood      SFPUC 100-Year Storm Flood Risk Zone + Flood Elevations (GeoJSON)
  spot_elev        USGS EPQS ground elevations at named demo points (ft NAVD88 ~= ft MLLW here)
  dem_index        USGS 3DEP 1 m DEM tile list for both sites (--download-dem to fetch GeoTIFFs)

Writes under data/raw/ (gitignored) and a human-readable data/raw/SUMMARY.md.
Standard library only. Verified against live endpoints Oct 21, 2026.

Usage:
  python scripts/stage_data.py                 # all steps
  python scripts/stage_data.py --only kelvin_anomaly flood_levels
  python scripts/stage_data.py --download-dem
"""
from __future__ import annotations

import argparse
import json
import re
import statistics as stats
import sys
import urllib.parse
import urllib.request
from pathlib import Path

SITES = {
    "rain": {"name": "17th & Folsom", "lat": 37.7634, "lon": -122.4150,
             "bbox": (-122.4220, 37.7580, -122.4080, 37.7690)},
    "coast": {"name": "Ferry Building / Embarcadero", "lat": 37.7955, "lon": -122.3935,
              "bbox": (-122.3990, 37.7905, -122.3880, 37.8000)},
}
SPOT_POINTS = {
    "Ferry Bldg front plaza": (37.7953, -122.3940),
    "Embarcadero roadway at Market": (37.7946, -122.3950),
    "Harry Bridges Plaza": (37.7944, -122.3955),
    "Ferry Plaza bayside": (37.7958, -122.3925),
    "Embarcadero at Pier 1": (37.7978, -122.3965),
    "Embarcadero at Mission St": (37.7934, -122.3928),
    "17th & Folsom": (37.7634, -122.4150),
    "14th & Folsom": (37.7684, -122.4155),
    "Folsom & 18th": (37.7617, -122.4153),
}
STATION = "9414290"
REPLAY = ("20221230", "20230102")
OUT = Path(__file__).resolve().parent.parent / "data" / "raw"
UA = {"User-Agent": "waterline-hackathon-prep/0.2"}
COOPS = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"
MDAPI = f"https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/{STATION}"
SUMMARY: list[str] = []


def get(url: str, params: dict | None = None, timeout: int = 90) -> bytes:
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read()


def getj(url: str, params: dict | None = None):
    return json.loads(get(url, params))


def save(name: str, data) -> Path:
    p = OUT / name
    p.parent.mkdir(parents=True, exist_ok=True)
    if not isinstance(data, (bytes, str)):
        data = json.dumps(data, indent=1)
    p.write_bytes(data if isinstance(data, bytes) else data.encode())
    print(f"  wrote {p.relative_to(OUT.parent.parent)} ({p.stat().st_size:,} bytes)")
    return p


def note(line: str) -> None:
    print("  " + line)
    SUMMARY.append(line)


def coops(product: str, b: str, e: str, **extra):
    p = {"product": product, "station": STATION, "begin_date": b, "end_date": e,
         "datum": "MLLW", "units": "english", "time_zone": "gmt", "format": "json",
         "application": "waterline", **extra}
    d = getj(COOPS, p)
    return d.get("data") or d.get("predictions") or []


def residual(b: str, e: str, product: str = "hourly_height"):
    obs = coops(product, b, e)
    pred = coops("predictions", b, e, **({"interval": "h"} if product == "hourly_height" else {}))
    pm = {x["t"]: float(x["v"]) for x in pred}
    r = [float(x["v"]) - pm[x["t"]] for x in obs if x.get("v") and x["t"] in pm]
    return (round(stats.mean(r), 2), round(max(r), 2), len(r)) if r else None


# ---------------------------------------------------------------- steps
_datums: dict[str, float] = {}


def tide_datums():
    d = getj(f"{MDAPI}/datums.json", {"units": "english"})
    save(f"tide_datums_{STATION}.json", d)
    _datums.update({x["name"]: x["value"] for x in d["datums"]})
    note(f"Datums (ft above STND): MLLW {_datums['MLLW']}, MHHW {_datums['MHHW']}, "
         f"NAVD88 {_datums['NAVD88']} -> MHHW = {_datums['MHHW'] - _datums['MLLW']:.2f} ft MLLW; "
         f"NAVD88 zero = {_datums['NAVD88'] - _datums['MLLW']:+.2f} ft MLLW")


def flood_levels():
    if not _datums:
        tide_datums()
    fl = getj(f"{MDAPI}/floodlevels.json", {"units": "english"})
    mllw = _datums["MLLW"]
    conv = {k: round(v - mllw, 2) for k, v in fl.items() if isinstance(v, (int, float))}
    save("flood_levels_mllw.json", {"source_stnd": fl, "ft_mllw": conv})
    note("Coastal flood thresholds at SF gauge (ft MLLW): " +
         ", ".join(f"{k} {v}" for k, v in conv.items()))


def king_tides():
    highs = []
    for b, e in [("20261101", "20261130"), ("20261201", "20261231"),
                 ("20270101", "20270131"), ("20270201", "20270228")]:
        highs += [p for p in coops("predictions", b, e, interval="hilo", time_zone="lst_ldt")
                  if p.get("type") == "H"]
    highs.sort(key=lambda p: float(p["v"]), reverse=True)
    save(f"tide_predictions_hilo_{STATION}.json", highs)
    note("Top predicted highs (ft MLLW, local): " +
         "; ".join(f"{p['t']} {p['v']}" for p in highs[:6]))


def kelvin_anomaly():
    rows = {}
    for label, b, e, prod in [
        ("Oct 2026 to date", "20261001", "20261031", "water_level"),
        ("Sep 2026", "20260901", "20260930", "hourly_height"),
        ("Oct 2025 (baseline)", "20251001", "20251031", "hourly_height"),
        ("Dec 2022 (replay month)", "20221201", "20221231", "hourly_height"),
        ("Jan 1983", "19830101", "19830131", "hourly_height"),
        ("Dec 1997", "19971201", "19971231", "hourly_height"),
        ("Jan 1998", "19980101", "19980131", "hourly_height"),
        ("Feb 1998", "19980201", "19980228", "hourly_height"),
    ]:
        try:
            rows[label] = residual(b, e, prod)
        except Exception as ex:  # one month failing shouldn't kill the table
            rows[label] = f"ERR {ex}"
    save("kelvin_anomaly.json", rows)
    note("Observed minus predicted water level at SF (mean / max ft, n):")
    for k, v in rows.items():
        note(f"  {k}: {v}")


def replay_tide():
    save(f"water_level_{STATION}_{REPLAY[0]}_{REPLAY[1]}.json",
         coops("water_level", *REPLAY))


def atlas14():
    s = SITES["rain"]
    txt = get("https://hdsc.nws.noaa.gov/cgi-bin/hdsc/new/cgi_readH5.py",
              {"lat": s["lat"], "lon": s["lon"], "type": "pf", "data": "depth",
               "units": "english", "series": "pds"}).decode()
    save("atlas14_pfds_raw.txt", txt)
    m = re.search(r"quantiles\s*=\s*(\[\[.*?\]\]);", txt, re.S)
    if not m:
        note("WARN Atlas 14: could not parse quantiles")
        return
    q = json.loads(m.group(1).replace("'", '"'))
    durs = ["5-min", "10-min", "15-min", "30-min", "60-min", "2-hr", "3-hr", "6-hr", "12-hr",
            "24-hr", "2-day", "3-day", "4-day", "7-day", "10-day", "20-day", "30-day",
            "45-day", "60-day"]
    aris = [1, 2, 5, 10, 25, 50, 100, 200, 500, 1000]
    table = {d: dict(zip(map(str, aris), map(float, row))) for d, row in zip(durs, q)}
    save("atlas14_pfds.json", {"lat": s["lat"], "lon": s["lon"], "units": "in",
                               "ari_years": aris, "depth": table})
    t = table["24-hr"]
    note(f"Atlas 14 24-hr depth at 17th & Folsom (in): 2-yr {t['2']}, 10-yr {t['10']}, "
         f"25-yr {t['25']}, 100-yr {t['100']}; 1-hr 100-yr {table['60-min']['100']}")


def rain_daily():
    d = getj("https://www.ncei.noaa.gov/access/services/data/v1",
             {"dataset": "daily-summaries", "stations": "USW00023272",
              "startDate": "2022-12-30", "endDate": "2023-01-01", "dataTypes": "PRCP",
              "format": "json", "units": "standard"})
    save("rain_daily_sf_downtown.json", d)
    note("SF Downtown daily PRCP (in): " + ", ".join(f"{x['DATE']} {x['PRCP']}" for x in d))


def rain_hourly():
    txt = get("https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py",
              {"station": "SFO", "data": "p01i", "year1": "2022", "month1": "12", "day1": "31",
               "year2": "2023", "month2": "1", "day2": "1", "tz": "America/Los_Angeles",
               "format": "onlycomma", "latlon": "no", "missing": "M", "trace": "T",
               "report_type": "3"}).decode()
    save("rain_hourly_sfo_20221231.csv", txt)
    vals = []
    for line in txt.strip().splitlines()[1:]:
        _, t, v = line.split(",")
        vals.append((t, 0.0 if v in ("M", "T") else float(v)))
    tot = sum(v for _, v in vals)
    pk = max(vals, key=lambda x: x[1]) if vals else ("-", 0)
    note(f"SFO hourly (shape only, DERIVED for downtown): total {tot:.2f} in, "
         f"peak hour {pk[0]} {pk[1]:.2f} in")


def sf311_flooding():
    for key, s in SITES.items():
        d = getj("https://data.sfgov.org/resource/vw6y-z8j6.json",
                 {"$select": "requested_datetime,address,lat,long,service_details",
                  "$where": ("service_subtype='Flooding' AND requested_datetime between "
                             "'2022-12-30T00:00:00' and '2023-01-02T00:00:00' AND "
                             f"within_circle(point,{s['lat']},{s['lon']},600)"),
                  "$order": "requested_datetime", "$limit": "500"})
        save(f"sf311_flooding_{key}_replay.json", d)
        note(f"311 flooding reports within 600 m of {s['name']}, Dec 30 - Jan 1: {len(d)}")
    tot = getj("https://data.sfgov.org/resource/vw6y-z8j6.json",
               {"$select": "count(*)", "$where": ("service_subtype='Flooding' AND "
                "requested_datetime between '2022-12-30T00:00:00' and '2023-01-02T00:00:00'")})
    note(f"311 flooding reports citywide, same window: {tot[0].get('count')}")


def sfpuc_flood():
    for rid, name in [("jzu3-4yxp", "sfpuc_100yr_flood_risk_zone_2022.geojson"),
                      ("wppz-u2hi", "sfpuc_100yr_flood_elevations_2024.geojson")]:
        save(name, get(f"https://data.sf.gov/api/v3/views/{rid}/query.geojson",
                       {"accessType": "DOWNLOAD"}, timeout=180))
    note("SFPUC 100-yr layers saved. Flood elevations are in SF City Datum: "
         "NAVD88 = SFCD + 11.35 ft (City & County Surveyor constant)")


def spot_elev():
    out = {}
    for k, (la, lo) in SPOT_POINTS.items():
        d = getj("https://epqs.nationalmap.gov/v1/json",
                 {"x": lo, "y": la, "units": "Feet", "wkid": 4326, "includeDate": "false"})
        out[k] = round(float(d["value"]), 1)
    save("spot_elevations_navd88_ft.json", out)
    note("Ground elevation (ft NAVD88, ~= ft MLLW at SF): " +
         "; ".join(f"{k} {v}" for k, v in out.items()))


def dem_index(download: bool = False):
    for key, s in SITES.items():
        raw = getj("https://tnmaccess.nationalmap.gov/api/v1/products",
                   {"datasets": "Digital Elevation Model (DEM) 1 meter",
                    "bbox": ",".join(map(str, s["bbox"])), "prodFormats": "GeoTIFF", "max": 50})
        items = [{"title": i.get("title"), "url": i.get("downloadURL"),
                  "size": i.get("sizeInBytes")} for i in raw.get("items", [])]
        save(f"dem_tiles_{key}.json", items)
        best = [i for i in items if "CA_SanFrancisco_B23" in (i["title"] or "")]
        note(f"DEM tiles for {s['name']}: " + ", ".join(i["title"] for i in (best or items)))
        if download:
            for i in best or items:
                save(f"dem/{i['url'].rsplit('/', 1)[-1]}", get(i["url"], timeout=900))


STEPS = ["tide_datums", "flood_levels", "king_tides", "kelvin_anomaly", "replay_tide",
         "atlas14", "rain_daily", "rain_hourly", "sf311_flooding", "sfpuc_flood",
         "spot_elev", "dem_index"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", choices=STEPS)
    ap.add_argument("--download-dem", action="store_true")
    a = ap.parse_args()
    failed = []
    for name in a.only or STEPS:
        print(f"[{name}]")
        try:
            fn = globals()[name]
            fn(a.download_dem) if name == "dem_index" else fn()
        except Exception as ex:
            failed.append(name)
            print(f"  ERROR: {ex}", file=sys.stderr)
    save("SUMMARY.md", "# Staging summary\n\n" + "\n".join(f"- {s}" for s in SUMMARY) + "\n")
    print(f"\nDone. {len(a.only or STEPS) - len(failed)} ok, failed: {failed or 'none'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
