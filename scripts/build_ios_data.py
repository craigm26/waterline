"""Pack the citywide lidar answers the iOS app needs to work anywhere in San Francisco, offline.

For every 5 m cell of the USGS 3DEP bare-earth DEM (data/terrain/sf_dem_5m.tif):
  ground   ground elevation, cm NAVD88                                   (derived from lidar)
  fill     priority-flood level from the open Bay/ocean, cm NAVD88       (derived)
           = the lowest still-water level at which water can reach this cell overland.
           fill - ground = bowl depth: how deep rain ponds here before it can spill.

Seeds are land cells next to open water. The San Mateo county line is also no-data in the clip,
so seeds whose water neighbour lies on the county-line strip are dropped; otherwise the county
line would act like a shoreline.

Writes ios/Waterline/Resources/:
  sfgrid.bin    header JSON line, then raw-deflate(int16 ground cm) and raw-deflate(uint16 bowl cm)
  places.json   top-500 drains, 50 low spots, 311 flooding reports (lon/lat/date), SFPUC zone
Usage: python scripts/build_ios_data.py [--check]
"""
import argparse, heapq, json, struct, zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "Waterline" / "Resources"
COUNTY_LINE_LAT = 37.7083   # SF / San Mateo line, roughly straight between the coasts


def seeds_mask(z, T, crs):
    from pyproj import Transformer
    water = np.isnan(z)
    land = ~water
    adj = np.zeros_like(land)
    for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
        adj |= np.roll(np.roll(water, dr, 0), dc, 1)
    seed = land & adj
    # drop seeds on the county-line strip (south edge, between the two coasts)
    rows, cols = np.nonzero(seed)
    xs = T.c + (cols + 0.5) * T.a
    ys = T.f + (rows + 0.5) * T.e
    lon, lat = Transformer.from_crs(crs, "EPSG:4326", always_xy=True).transform(xs, ys)
    county = (lat < COUNTY_LINE_LAT + 0.0012) & (lon > -122.497) & (lon < -122.392)
    seed[rows[county], cols[county]] = False
    return seed, int(county.sum())


def priority_flood(z, seed):
    h, w = z.shape
    f = np.where(np.isnan(z), np.nan, np.inf)
    done = np.isnan(z).copy()
    pq = []
    for r, c in zip(*np.nonzero(seed)):
        f[r, c] = z[r, c]; done[r, c] = True; pq.append((float(z[r, c]), int(r), int(c)))
    heapq.heapify(pq)
    while pq:
        e, r, c = heapq.heappop(pq)
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                rr, cc = r + dr, c + dc
                if 0 <= rr < h and 0 <= cc < w and not done[rr, cc]:
                    done[rr, cc] = True
                    v = max(e, float(z[rr, cc])); f[rr, cc] = v
                    heapq.heappush(pq, (v, rr, cc))
    # land never reached from a seed (enclosed by the county strip): treat as its own outlet
    unreached = np.isinf(f)
    f[unreached] = z[unreached]
    return f, int(unreached.sum())


def deflate(b):
    """Raw DEFLATE (no zlib header): what Apple's Compression framework calls COMPRESSION_ZLIB."""
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(b) + c.flush()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--check", action="store_true"); a = ap.parse_args()
    import rasterio
    with rasterio.open(ROOT / "data/terrain/sf_dem_5m.tif") as s:
        z = s.read(1).astype("float64"); T = s.transform; crs = s.crs
    seed, dropped = seeds_mask(z, T, crs)
    print(f"DEM {z.shape}, seeds {int(seed.sum())} (dropped {dropped} on the county line); flooding ...")
    f, unreached = priority_flood(z, seed)
    print(f"unreached land cells: {unreached}")
    nod = np.isnan(z)
    ground = np.where(nod, -32768, np.round(z * 100)).astype("<i2")
    bowl = np.where(nod, 0, np.clip(np.round((f - z) * 100), 0, 65535)).astype("<u2")
    OUT.mkdir(parents=True, exist_ok=True)
    g, b = deflate(ground.tobytes()), deflate(bowl.tobytes())
    hdr = {"schema": "waterline.sfgrid.v1", "crs": "EPSG:26910", "rows": z.shape[0], "cols": z.shape[1],
           "x0": T.c, "y0": T.f, "res_m": T.a, "nodata_ground": -32768,
           "ground": {"dtype": "int16le", "unit": "cm NAVD88", "bytes": len(g)},
           "bowl": {"dtype": "uint16le", "unit": "cm", "bytes": len(b)},
           "mllw_minus_navd88_ft_sf": -0.06, "compression": "raw deflate", "note": "fill = ground + bowl = lowest Bay level that reaches the cell overland",
           "source": "USGS 3DEP 1 m lidar DEM (CA_SanFrancisco_B23), resampled to 5 m; priority flood from open water"}
    (OUT / "sfgrid.bin").write_bytes(json.dumps(hdr).encode() + b"\n" + g + b)
    print(f"sfgrid.bin {(len(g) + len(b)) / 1e6:.1f} MB (ground {len(g) / 1e6:.1f}, bowl {len(b) / 1e6:.1f})")

    city = json.loads((ROOT / "site/data/city.json").read_text())
    fl = json.loads((ROOT / "site/data/flood311.json").read_text())
    zone = json.loads((ROOT / "site/data/sfpuc_100yr.geojson").read_text())
    F = city["drain_fields"]
    drains = []
    for row in city["drains_top500"]:
        d = dict(zip(F, row))
        drains.append({"rank": d["rank"], "id": d["asset_id"], "lon": round(d["lon"], 6), "lat": round(d["lat"], 6),
                       "sump_m": round(float(d["sump_m"]), 2), "flood311": int(d["flood311_75m"]),
                       "hood": d.get("neighborhood") or "", "deep_pit": float(d["sump_m"]) > city["deep_pit_m"]})
    hot = [{"rank": h["rank"], "name": h.get("name") or h.get("neighborhood") or f"Low spot #{h['rank']}",
            "lon": round(h["lon"], 6), "lat": round(h["lat"], 6), "max_depth_m": h["max_depth_m"], "area_m2": h["area_m2"],
            "flood311": h["flood311_150m"], "in_zone": bool(h["in_sfpuc_100yr"])} for h in city["hotspots"]]
    rings = []
    for f in zone["features"]:
        g = f["geometry"]; polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        for poly in polys:
            for ring in poly:
                rings.append([[round(x, 5), round(y, 5)] for x, y in ring])
    places = {"schema": "waterline.places.v1", "drains": drains, "hotspots": hot,
              "flood311": [[round(x, 5), round(y, 5)] for x, y in fl], "zone_rings": rings,
              "sources": city["sources"], "flood311_total": len(fl)}
    (OUT / "places.json").write_text(json.dumps(places, separators=(",", ":")))
    print(f"places.json {(OUT / 'places.json').stat().st_size / 1e6:.2f} MB; {len(drains)} drains, {len(hot)} low spots, "
          f"{len(fl)} 311 reports, {len(rings)} zone rings / {sum(map(len, rings))} vertices")

    if a.check:
        from pyproj import Transformer
        tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
        for name, lon, lat in [("Ferry Building plaza", -122.3935, 37.7955), ("17th & Folsom", -122.4148, 37.7633),
                               ("Marina Green", -122.4381, 37.8063), ("Mission Bay, 4th & Channel", -122.3920, 37.7740),
                               ("Twin Peaks", -122.4475, 37.7544), ("Lower Great Hwy at Judah", -122.5085, 37.7605)]:
            x, y = tr.transform(lon, lat); c = int((x - T.c) / T.a); r = int((y - T.f) / T.e)
            gz, ff = z[r, c], f[r, c]
            print(f"{name:28s} ground {gz * 3.28084 - 0.06:6.2f} ft MLLW · Bay reaches at {ff * 3.28084 - 0.06:6.2f} · bowl {(ff - gz) * 3.28084:5.2f} ft")


if __name__ == "__main__":
    main()
