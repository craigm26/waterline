#!/usr/bin/env python3
"""Pre-stage public data for the Waterline demo site (17th & Folsom, SF).

Pulls:
  1. NOAA CO-OPS tidal datums for station 9414290
  2. NOAA CO-OPS high/low tide predictions (Nov 2026 - Feb 2027) -> king-tide candidates
  3. NOAA CO-OPS observed water level for the replay storm window
  4. NOAA Atlas 14 precipitation-frequency estimates (PDS, depth, inches) at the site
  5. USGS 3DEP 1 m DEM tile list (TNM Access API) for the site bbox, with download URLs

Writes everything under data/raw/ (gitignored). Standard library only.

Status: written ahead of the event and NOT yet run against the live endpoints.
Run it on a machine with normal internet access and check the output.

Usage:
  python scripts/stage_data.py
  python scripts/stage_data.py --replay-start 20221230 --replay-end 20230105
  python scripts/stage_data.py --download-dem   # actually fetch the GeoTIFFs (large)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

SITE_LAT, SITE_LON = 37.7634, -122.4150
BBOX = (-122.4220, 37.7580, -122.4080, 37.7690)  # minx, miny, maxx, maxy
STATION = "9414290"
OUT = Path(__file__).resolve().parent.parent / "data" / "raw"
UA = {"User-Agent": "waterline-hackathon-prep/0.1"}

COOPS = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"
COOPS_MD = f"https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/{STATION}/datums.json"
PFDS = "https://hdsc.nws.noaa.gov/cgi-bin/hdsc/new/cgi_readH5.py"
TNM = "https://tnmaccess.nationalmap.gov/api/v1/products"


def get(url: str, params: dict | None = None) -> bytes:
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def save(name: str, data: bytes | str) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    p = OUT / name
    p.write_bytes(data if isinstance(data, bytes) else data.encode())
    print(f"  wrote {p.relative_to(OUT.parent.parent)} ({p.stat().st_size:,} bytes)")
    return p


def tide_datums() -> None:
    print("[1] Tidal datums")
    save(f"tide_datums_{STATION}.json", get(COOPS_MD, {"units": "english"}))


def king_tides() -> None:
    print("[2] High/low predictions, Nov 2026 - Feb 2027")
    months = [("20261101", "20261130"), ("20261201", "20261231"),
              ("20270101", "20270131"), ("20270201", "20270228")]
    highs = []
    for b, e in months:
        raw = json.loads(get(COOPS, {
            "product": "predictions", "station": STATION, "begin_date": b, "end_date": e,
            "datum": "MLLW", "units": "english", "time_zone": "lst_ldt",
            "interval": "hilo", "format": "json", "application": "waterline"}))
        highs += [p for p in raw.get("predictions", []) if p.get("type") == "H"]
    highs.sort(key=lambda p: float(p["v"]), reverse=True)
    save(f"tide_predictions_hilo_{STATION}.json", json.dumps(highs, indent=1))
    print("  top 10 predicted highs (ft MLLW):")
    for p in highs[:10]:
        print(f"    {p['t']}  {p['v']}")


def replay_water_level(start: str, end: str) -> None:
    print(f"[3] Observed water level {start}-{end}")
    save(f"water_level_{STATION}_{start}_{end}.json", get(COOPS, {
        "product": "water_level", "station": STATION, "begin_date": start, "end_date": end,
        "datum": "MLLW", "units": "english", "time_zone": "lst_ldt",
        "format": "json", "application": "waterline"}))  # API max ~31 days per call


def atlas14() -> None:
    print("[4] Atlas 14 PFDS (depth, inches, partial-duration series)")
    txt = get(PFDS, {"lat": SITE_LAT, "lon": SITE_LON, "type": "pf",
                     "data": "depth", "units": "english", "series": "pds"}).decode()
    save("atlas14_pfds_raw.txt", txt)
    m = re.search(r"quantiles\s*=\s*(\[\[.*?\]\]);", txt, re.S)
    if not m:
        print("  WARN: could not parse quantiles; inspect atlas14_pfds_raw.txt")
        return
    q = json.loads(m.group(1).replace("'", '"'))
    durations = ["5-min", "10-min", "15-min", "30-min", "60-min", "2-hr", "3-hr", "6-hr",
                 "12-hr", "24-hr", "2-day", "3-day", "4-day", "7-day", "10-day",
                 "20-day", "30-day", "45-day", "60-day"]
    aris = [1, 2, 5, 10, 25, 50, 100, 200, 500, 1000]
    table = {d: dict(zip(map(str, aris), map(float, row))) for d, row in zip(durations, q)}
    save("atlas14_pfds.json", json.dumps({"lat": SITE_LAT, "lon": SITE_LON,
                                          "units": "in", "ari_years": aris,
                                          "depth": table}, indent=1))
    print(f"  24-hr: 2-yr {table['24-hr']['2']} in, 100-yr {table['24-hr']['100']} in")


def dem_index(download: bool) -> None:
    print("[5] USGS 3DEP 1 m DEM tiles")
    raw = json.loads(get(TNM, {"datasets": "Digital Elevation Model (DEM) 1 meter",
                               "bbox": ",".join(map(str, BBOX)),
                               "prodFormats": "GeoTIFF", "max": 50}))
    items = [{"title": i.get("title"), "url": i.get("downloadURL"),
              "date": i.get("publicationDate"), "size": i.get("sizeInBytes")}
             for i in raw.get("items", [])]
    save("dem_tiles.json", json.dumps(items, indent=1))
    for i in items:
        print(f"    {i['title']}  ({(i['size'] or 0) / 1e6:.0f} MB)")
    if download:
        for i in items:
            name = i["url"].rsplit("/", 1)[-1]
            print(f"  downloading {name} ...")
            save(name, get(i["url"]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--replay-start", default="20221230")
    ap.add_argument("--replay-end", default="20230105")
    ap.add_argument("--download-dem", action="store_true")
    a = ap.parse_args()
    steps = [tide_datums, king_tides,
             lambda: replay_water_level(a.replay_start, a.replay_end),
             atlas14, lambda: dem_index(a.download_dem)]
    failed = 0
    for step in steps:
        try:
            step()
        except Exception as e:  # keep going; report at the end
            failed += 1
            print(f"  ERROR: {e}", file=sys.stderr)
    print(f"\nDone. {len(steps) - failed}/{len(steps)} steps succeeded. Output: {OUT}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
