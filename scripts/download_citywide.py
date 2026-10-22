#!/usr/bin/env python3
"""Resumable bulk downloads for the citywide views (run on a machine with normal internet).

    python scripts/download_citywide.py                 # everything
    python scripts/download_citywide.py --only photos drains311

Steps
  photos     NYE-2022 311 citizen flood photos near 17th & Folsom (skips dead links)
  drains     ALL SFPUC storm-drain inlets (DataSF jtgq-b7c5, ~25k)            -> data/raw/citywide/drains.geojson
  flood311   ALL SF 311 "Sewer Issues / Flooding" reports with coordinates    -> data/raw/citywide/sf311_flooding.json
  sfpuc      SFPUC 100-yr zone + flood elevations (citywide)                  -> data/raw/citywide/
  dem        USGS 3DEP 1 m DEM tiles covering San Francisco (CA_SanFrancisco_B23, ~1-2 GB)
                                                                              -> data/raw/citywide/dem/*.tif
Everything streams to disk in chunks (low memory) and skips files already complete.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "raw" / "citywide"
UA = {"User-Agent": "waterline-hackathon-prep/0.6"}
SF_BBOX = (-122.5155, 37.7080, -122.3550, 37.8325)   # land SF, excluding the Farallons


def getj(url, params=None, timeout=120):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return json.loads(r.read())


def stream(url, dst: Path, expect: int | None = None, timeout=300):
    if dst.exists() and (expect is None or dst.stat().st_size == expect):
        print(f"  skip {dst.name} (have it)")
        return
    tmp = dst.with_suffix(dst.suffix + ".part")
    dst.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r, open(tmp, "wb") as f:
        n = 0
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b); n += len(b)
    tmp.replace(dst)
    print(f"  got {dst.name} ({n/1e6:.1f} MB)")


def photos():
    out = ROOT / "data" / "ground_truth" / "nye311_photos"
    out.mkdir(parents=True, exist_ok=True)
    d = getj("https://data.sfgov.org/resource/vw6y-z8j6.json", {
        "$select": "service_request_id,requested_datetime,address,lat,long,media_url,service_details",
        "$where": ("service_subtype='Flooding' AND requested_datetime between '2022-12-30T00:00:00' and "
                   "'2023-01-02T00:00:00' AND within_circle(point,37.7634,-122.4150,600) AND media_url IS NOT NULL"),
        "$order": "requested_datetime", "$limit": "50"})
    meta = []
    for x in d:
        u = x["media_url"]["url"].replace("http://", "https://")
        sid = x.get("service_request_id") or u.split("/")[-2]
        try:
            stream(u, out / f"{sid}.jpg")
        except Exception as ex:
            print(f"  {sid}: {ex} (skipped)")
            continue
        meta.append({"id": sid, "time": x["requested_datetime"], "address": x.get("address"),
                     "lat": float(x["lat"]), "lon": float(x["long"]), "kind": x.get("service_details"),
                     "file": f"{sid}.jpg", "source": u, "credit": "SF 311 public record (DataSF vw6y-z8j6)"})
    json.dump(meta, open(out / "photos.json", "w"), indent=1)
    print(f"  {len(meta)} photos")


def drains():
    stream("https://data.sf.gov/api/v3/views/jtgq-b7c5/query.geojson?accessType=DOWNLOAD",
           OUT / "drains.geojson", timeout=600)


def flood311():
    rows, off = [], 0
    while True:
        d = getj("https://data.sfgov.org/resource/vw6y-z8j6.json", {
            "$select": "service_request_id,requested_datetime,lat,long,service_details",
            "$where": "service_subtype='Flooding' AND lat IS NOT NULL",
            "$order": "service_request_id", "$limit": "50000", "$offset": str(off)}, timeout=300)
        rows += d; off += len(d)
        print(f"  311 flooding rows: {off}")
        if len(d) < 50000:
            break
    json.dump(rows, open(OUT / "sf311_flooding.json", "w"))


def sfpuc():
    for rid, name in [("jzu3-4yxp", "sfpuc_100yr_zone.geojson"), ("wppz-u2hi", "sfpuc_100yr_elevations.geojson")]:
        stream(f"https://data.sf.gov/api/v3/views/{rid}/query.geojson?accessType=DOWNLOAD", OUT / name, timeout=600)


def dem():
    d = getj("https://tnmaccess.nationalmap.gov/api/v1/products",
             {"datasets": "Digital Elevation Model (DEM) 1 meter", "bbox": ",".join(map(str, SF_BBOX)),
              "prodFormats": "GeoTIFF", "max": 100})
    items = [i for i in d.get("items", []) if "CA_SanFrancisco_B23" in (i.get("title") or "")]
    tot = sum(i.get("sizeInBytes") or 0 for i in items)
    print(f"  {len(items)} tiles, {tot/1e9:.2f} GB")
    json.dump([{"title": i["title"], "url": i["downloadURL"], "size": i.get("sizeInBytes")} for i in items],
              open(OUT / "dem_tiles.json", "w"), indent=1)
    for i in items:
        stream(i["downloadURL"], OUT / "dem" / i["downloadURL"].rsplit("/", 1)[-1], i.get("sizeInBytes"), timeout=1800)


STEPS = {"photos": photos, "drains": drains, "flood311": flood311, "sfpuc": sfpuc, "dem": dem}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", choices=list(STEPS))
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    bad = []
    for k in a.only or STEPS:
        print(f"[{k}]")
        try:
            STEPS[k]()
        except Exception as ex:
            bad.append(k); print(f"  ERROR {ex}", file=sys.stderr)
    print("DONE", "failed:", bad or "none")


if __name__ == "__main__":
    main()
