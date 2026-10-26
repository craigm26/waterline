#!/usr/bin/env python3
"""Pack the citywide analysis into site/data/ for the city-manager view.

Reads data/derived/citywide/ (drain_rank.csv, hotspots.geojson, summary.json,
sf311_flooding.csv, sfpuc_100yr_zone.geojson) and writes:
  site/data/city.json          top 500 drains, 50 low spots, crew zones, summary
  site/data/flood311.json      every 311 flooding report as [lon, lat] (5 decimals)
  site/data/sfpuc_100yr.geojson  the city's 100-year storm flood zone, as published
  site/data/top500_drains.csv  the crew list, for download

Standard library only, so it runs anywhere:  python3 scripts/build_city_data.py
"""
import collections, csv, json, math, pathlib, shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]
C = ROOT / "data/derived/citywide"
OUT = ROOT / "site/data"
# Named in plan/story.md from site visits and the lidar drill-downs
NAMES = {1: "SoMa by Mission Creek", 2: "14th-15th & Folsom", 3: "Lower Great Highway",
         4: "Islais Creek / Dogpatch", 7: "Bayview, 3rd St"}
DEEP_PIT_M = 2.0  # sumps deeper than this are underpasses and stairwells: verify, don't send a street crew


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rows = list(csv.DictReader(open(C / "drain_rank.csv", encoding="utf-8")))
    top = [r for r in rows if int(r["rank"]) <= 500]
    drains = [[int(r["rank"]), r["asset_id"], round(float(r["lon"]), 6), round(float(r["lat"]), 6),
               round(float(r["sump_m"]), 2), int(float(r["captured_m2"])), int(r["flood311_75m"]),
               r["neighborhood"], r["drain_type"]] for r in top]
    street = [r for r in top if float(r["sump_m"]) <= DEEP_PIT_M]
    zones = collections.Counter(r["neighborhood"] for r in street).most_common()

    def nearest_hood(lon, lat):
        k = math.cos(math.radians(lat))
        r = min(rows, key=lambda r: ((float(r["lon"]) - lon) * k) ** 2 + (float(r["lat"]) - lat) ** 2)
        return r["neighborhood"]

    hot = []
    for f in json.load(open(C / "hotspots.geojson"))["features"][:50]:
        p = f["properties"]; lon, lat = f["geometry"]["coordinates"]
        hot.append({"rank": p["rank"], "name": NAMES.get(p["rank"]), "neighborhood": nearest_hood(lon, lat),
                    "lon": round(lon, 6), "lat": round(lat, 6), "area_m2": int(p["area_m2"]),
                    "max_depth_m": round(p["max_depth_m"], 2), "volume_m3": int(p["volume_m3"]),
                    "flood311_150m": p["flood311_150m"], "in_sfpuc_100yr": bool(p["in_sfpuc_100yr"])})

    city = {
        "schema": "waterline.city.v1",
        "summary": json.load(open(C / "summary.json")),
        "drain_fields": ["rank", "asset_id", "lon", "lat", "sump_m", "captured_m2", "flood311_75m", "neighborhood", "drain_type"],
        "drains_top500": drains,
        "street_drains": len(street),
        "deep_pit_drains": len(top) - len(street),
        "deep_pit_m": DEEP_PIT_M,
        "zones": zones,
        "hotspots": hot,
        "sources": {
            "drains": "SFPUC / DataSF jtgq-b7c5 (Adopt-a-Drain inlets)",
            "terrain": "USGS 3DEP 1 m lidar DEM, resampled to 5 m",
            "flood311": "SF311 cases, category Sewer / flooding, via DataSF",
            "sfpuc_zone": "SFPUC 100-year storm flood risk map",
        },
    }
    (OUT / "city.json").write_text(json.dumps(city, separators=(",", ":")))
    f311 = [[round(float(r["lon"]), 5), round(float(r["lat"]), 5)]
            for r in csv.DictReader(open(C / "sf311_flooding.csv", encoding="utf-8"))]
    (OUT / "flood311.json").write_text(json.dumps(f311, separators=(",", ":")))
    shutil.copyfile(C / "sfpuc_100yr_zone.geojson", OUT / "sfpuc_100yr.geojson")
    with open(OUT / "top500_drains.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh); w.writerow(city["drain_fields"] + ["crew"])
        for d in drains:
            w.writerow(d + ["street" if d[4] <= DEEP_PIT_M else "verify (deep pit)"])
    print(f"site/data: {len(drains)} drains ({len(street)} street), {len(hot)} low spots, {len(f311)} 311 reports, {len(zones)} zones")


if __name__ == "__main__":
    main()
