#!/usr/bin/env python3
"""Megastorm rain for California cities: ios/Waterline/Resources/arkstorm.json.

Two sources, both reusable:
- ARkStorm 2.0 (Huang & Swain 2022, Science Advances; data on DesignSafe, doi:10.17603/ds2-mzgn-cy51,
  Open Data Commons Attribution): WRF hourly precipitation on a 3 km grid for two 30-day California
  megastorm scenarios, today's climate ("hist") and a warmer late-century one ("ftr"). This keeps
  the hourly series at the 3 km cell nearest each city.
- The Great Flood of 1861-62 as measured: NOAA daily rain gauge readings (via RCC-ACIS,
  public domain) at San Francisco and Sacramento, the wettest 30 days of that winter.

Run once on a machine with ~2.5 GB free and numpy + scipy (the build Mac):
  python3 scripts/build_arkstorm.py OUT_JSON
"""
import json, sys, urllib.request
from pathlib import Path

CITIES = [
    ("San Francisco", 37.7749, -122.4194), ("Oakland", 37.8044, -122.2712), ("San Jose", 37.3382, -121.8863),
    ("Santa Rosa", 38.4405, -122.7144), ("Sacramento", 38.5816, -121.4944), ("Yuba City", 39.1404, -121.6169),
    ("Stockton", 37.9577, -121.2908), ("Redding", 40.5865, -122.3917), ("Eureka", 40.8021, -124.1637),
    ("Fresno", 36.7378, -119.7871), ("Bakersfield", 35.3733, -119.0187), ("Santa Barbara", 34.4208, -119.6982),
    ("Los Angeles", 34.0522, -118.2437), ("Long Beach", 33.7701, -118.1937), ("Riverside", 33.9806, -117.3755),
    ("San Diego", 32.7157, -117.1611),
]
API = "https://www.designsafe-ci.org/api/datafiles/tapis/public/preview/designsafe.storage.published/PRJ-3499/Post/wrf_pr_hourly_3km_arkevt_30day_{}.nc/"
WORK = Path.home() / "arkstorm"
UA = {"User-Agent": "Waterline arkstorm (https://github.com/craigm26/waterline)"}


def fetch(run):
    f = WORK / f"pr_{run}.nc"
    if f.exists() and f.stat().st_size > 1_000_000_000:
        return f
    with urllib.request.urlopen(urllib.request.Request(API.format(run), headers=UA), timeout=60) as r:
        href = json.load(r)["href"]
    print("downloading", run, flush=True)
    with urllib.request.urlopen(urllib.request.Request(href, headers=UA), timeout=600) as r, open(f, "wb") as out:
        while chunk := r.read(1 << 22):
            out.write(chunk)
    return f


def series(path):
    import numpy as np
    from scipy.io import netcdf_file
    nc = netcdf_file(str(path), "r", mmap=True)
    v = nc.variables
    pr = v["PRECT"]
    lat = np.array(v["lat"][:]); lon = np.array(v["lon"][:])
    while lat.ndim > 2: lat = lat[0]; lon = lon[0]
    units = pr.units.decode() if hasattr(pr, "units") and isinstance(pr.units, bytes) else getattr(pr, "units", "")
    out = {}
    for name, la, lo in CITIES:
        d = (lat - la) ** 2 + ((lon - lo) * np.cos(np.radians(la))) ** 2
        j, i = np.unravel_index(np.argmin(d), d.shape)
        km = float(np.sqrt(d[j, i]) * 111.2)
        vals = np.array(pr[:, :, j, i], dtype="float64").reshape(-1)   # time x hr -> hourly
        vals[vals > 1e30] = 0.0                                          # _FillValue
        if "m s-1" in units or "m/s" in units: vals = vals * 3600 * 1000      # m/s -> mm/h
        out[name] = {"cell": [round(float(lat[j, i]), 4), round(float(lon[j, i]), 4)], "km": round(km, 1),
                     "hourly_in": [round(x / 25.4, 3) for x in vals]}
    nc.close()
    return units, out


def acis(sid):
    body = json.dumps({"sid": sid, "sdate": "1861-11-01", "edate": "1862-02-28", "elems": ["pcpn"]}).encode()
    req = urllib.request.Request("https://data.rcc-acis.org/StnData", data=body, headers={**UA, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        d = json.load(r)
    days = [(row[0], 0.0 if row[1] in ("T", "M", "") else float(row[1])) for row in d["data"]]
    best = max(range(len(days) - 29), key=lambda k: sum(x for _, x in days[k:k + 30]))
    win = days[best:best + 30]
    return {"station": d["meta"]["name"], "sid": sid, "start": win[0][0], "daily_in": [x for _, x in win]}


def main():
    WORK.mkdir(exist_ok=True)
    res = {"source": {"arkstorm": "ARkStorm 2.0, Huang & Swain 2022 (Science Advances 8, eabq0995); WRF 3 km hourly precipitation, DesignSafe doi:10.17603/ds2-mzgn-cy51, ODC-By",
                      "1862": "NOAA daily precipitation, 1861-62, via RCC-ACIS (public domain)"},
           "cities": {}}
    for run in ("hist", "ftr"):
        units, s = series(fetch(run))
        print(run, "units", units, flush=True)
        for name, la, lo in CITIES:
            c = res["cities"].setdefault(name, {"lat": la, "lon": lo})
            c["cell"], c["km"] = s[name]["cell"], s[name]["km"]
            c[run] = s[name]["hourly_in"]
    for name in res["cities"]:
        c = res["cities"][name]
        print(name, c["km"], "km", "hist %.1f in" % sum(c["hist"]), "ftr %.1f in" % sum(c["ftr"]), "peak hr %.2f" % max(c["ftr"]), flush=True)
    res["1862"] = {"San Francisco": acis("047772"), "Sacramento": acis("SACthr 9")}
    for k, v in res["1862"].items():
        print("1862", k, v["start"], "%.2f in" % sum(v["daily_in"]), flush=True)
    Path(sys.argv[1]).write_text(json.dumps(res, separators=(",", ":")))


if __name__ == "__main__":
    main()
