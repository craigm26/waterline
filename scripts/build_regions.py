"""Build region packs for the iOS app: the SF lidar answer, generalized to other high-risk US cities.

For each region in regions/regions.json, read USGS 3DEP 1/3 arc-second (~10 m) Cloud-Optimized
GeoTIFFs straight from S3 (only the blocks needed), warp to UTM at 10 m, and compute:
  ground   cm NAVD88
  bowl     priority-flood depth, cm: how far the ground sits below the lowest rim that encloses it.
           Seeds are open water (3DEP no data) and the region's edge. Behind a levee, the rim is
           the levee, so in Natomas or New Orleans this is "how deep it gets if the basin fills".
Output: dist/regions/<id>_grid.bin, same layout as ios/Waterline/Resources/sfgrid.bin plus
"zone" and "bbox" in the header, and packs/manifest.json gains one pack per region.

Usage: python scripts/build_regions.py [--only sacramento miami] [--check]
"""
import argparse, hashlib, heapq, json, math, os, zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "dist/regions"
RES = 10.0
COG = "/vsicurl/https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current/{t}/USGS_13_{t}.tif"
REL = "https://github.com/craigm26/waterline/releases/download/packs-v1"
CHECKS = {
    "sacramento": [("Natomas, Del Paso Rd", -121.52, 38.65), ("Pocket, Greenhaven", -121.53, 38.49), ("Downtown, Capitol", -121.4936, 38.5766)],
    "new-orleans": [("Lakeview", -90.10, 30.00), ("French Quarter", -90.065, 29.958), ("Lower Ninth Ward", -90.01, 29.965)],
    "miami": [("Miami Beach, West Ave", -80.143, 25.785), ("Brickell", -80.193, 25.763)],
    "norfolk": [("The Hague, Ghent", -76.296, 36.862), ("Downtown", -76.29, 36.847)],
    "charleston": [("Market St", -79.931, 32.781), ("Lockwood Dr", -79.952, 32.781)],
    "houston": [("Meyerland", -95.462, 29.687), ("Downtown", -95.367, 29.758)],
    "nyc": [("Battery Park", -74.016, 40.703), ("Red Hook", -74.012, 40.676)],
    "boston": [("Seaport", -71.044, 42.351), ("Long Wharf", -71.05, 42.360)],
}


def tiles_for(b):
    w, s, e, n = b
    out = []
    for lat in range(math.floor(s) + 1, math.ceil(n) + 1):
        for lon in range(math.floor(-e) + 1, math.ceil(-w) + 1):
            out.append(f"n{lat:02d}w{lon:03d}")
    return out


def read_dem(r, pad=0.0):
    import rasterio
    from rasterio.enums import Resampling
    from rasterio.vrt import WarpedVRT
    from pyproj import Transformer
    tr = Transformer.from_crs(4326, r["epsg"], always_xy=True)
    w, s, e, n = r["bbox"]
    w, s, e, n = w - pad, s - pad, e + pad, n + pad
    xs, ys = zip(*[tr.transform(x, y) for x in (w, e) for y in (s, n)])
    x0, y1 = math.floor(min(xs) / RES) * RES, math.ceil(max(ys) / RES) * RES
    cols, rows = int(math.ceil((max(xs) - x0) / RES)), int(math.ceil((y1 - min(ys)) / RES))
    transform = rasterio.transform.from_origin(x0, y1, RES, RES)
    z = np.full((rows, cols), np.nan, dtype="float32")
    os.environ.setdefault("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
    with rasterio.Env(GDAL_HTTP_CAINFO=os.environ.get("CURL_CA_BUNDLE", "/root/.ccr/ca-bundle.crt"),
                      CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif", GDAL_HTTP_MAX_RETRY="4", GDAL_HTTP_RETRY_DELAY="2"):
        for t in tiles_for([w, s, e, n]):
            with rasterio.open(COG.format(t=t)) as src:
                with WarpedVRT(src, crs=f"EPSG:{r['epsg']}", transform=transform, width=cols, height=rows,
                               resampling=Resampling.bilinear, src_nodata=src.nodata, nodata=np.nan, dtype="float32") as v:
                    a = v.read(1)
            ok = ~np.isnan(a) & (a > -1000)
            z[ok] = a[ok]
    return z, x0, y1


def priority_flood(z):
    h, w = z.shape
    water = np.isnan(z)
    f = np.where(water, np.nan, np.inf)
    done = water.copy()
    seed = np.zeros_like(water)
    seed[0, :] = seed[-1, :] = True; seed[:, 0] = seed[:, -1] = True
    near = np.zeros_like(water)
    for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        near |= np.roll(np.roll(water, dr, 0), dc, 1)
    seed = (seed | near) & ~water
    pq = [(float(z[r, c]), int(r), int(c)) for r, c in zip(*np.nonzero(seed))]
    for _, r, c in pq:
        f[r, c] = z[r, c]; done[r, c] = True
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
    return f


def deflate(b):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(b) + c.flush()


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for ch in iter(lambda: fh.read(1 << 20), b""):
            h.update(ch)
    return h.hexdigest()


def build(r, check):
    # Flood on a padded area so a basin cut by the region's edge doesn't drain through the cut,
    # then crop back to the region.
    pad = r.get("pad_deg", 0.08)
    zp, px0, py1 = read_dem(r, pad)
    fp = priority_flood(zp.astype("float64"))
    z, x0, y1 = read_dem(r)
    c0, r0 = int(round((x0 - px0) / RES)), int(round((py1 - y1) / RES))
    f = fp[r0:r0 + z.shape[0], c0:c0 + z.shape[1]]
    z = zp[r0:r0 + z.shape[0], c0:c0 + z.shape[1]]
    land = ~np.isnan(z)
    print(f"{r['id']}: {z.shape[1]}x{z.shape[0]} @ {RES:.0f} m, land {land.mean():.0%}, ground p1/p50/p99 "
          f"{np.nanpercentile(z, 1) * 3.28084:.1f}/{np.nanpercentile(z, 50) * 3.28084:.1f}/{np.nanpercentile(z, 99) * 3.28084:.1f} ft NAVD88")
    ground = np.where(land, np.clip(np.round(z * 100), -32767, 32767), -32768).astype("<i2")
    bowl = np.where(land, np.clip(np.round((f - z) * 100), 0, 65535), 0).astype("<u2")
    g, b = deflate(ground.tobytes()), deflate(bowl.tobytes())
    hdr = {"schema": "waterline.sfgrid.v1", "region": r["id"], "name": r["name"], "crs": f"EPSG:{r['epsg']}",
           "zone": r["epsg"] - 26900, "bbox": r["bbox"], "rows": z.shape[0], "cols": z.shape[1], "x0": x0, "y0": y1,
           "res_m": RES, "nodata_ground": -32768, "compression": "raw deflate",
           "ground": {"dtype": "int16le", "unit": "cm NAVD88", "bytes": len(g)},
           "bowl": {"dtype": "uint16le", "unit": "cm", "bytes": len(b)},
           "note": "bowl = lowest enclosing rim (levee, ridge, road) minus ground; seeds are open water and the region edge",
           "source": "USGS 3DEP 1/3 arc-second DEM (COG on prd-tnm S3), warped to UTM at 10 m"}
    OUT.mkdir(parents=True, exist_ok=True)
    p = OUT / f"{r['id']}_grid.bin"
    p.write_bytes(json.dumps(hdr).encode() + b"\n" + g + b)
    deep = (bowl >= 152).sum() / max(land.sum(), 1)
    print(f"  -> {p.name} {p.stat().st_size / 1e6:.1f} MB; land in a bowl >= 5 ft: {deep:.1%}")
    if check:
        from pyproj import Transformer
        tr = Transformer.from_crs(4326, r["epsg"], always_xy=True)
        for name, lon, lat in CHECKS.get(r["id"], []):
            x, y = tr.transform(lon, lat); c, rr = int((x - x0) / RES), int((y1 - y) / RES)
            if not land[rr, c]:
                print(f"  {name:24s} water/no data"); continue
            print(f"  {name:24s} ground {z[rr, c] * 3.28084:6.1f} ft NAVD88, rim {f[rr, c] * 3.28084:6.1f}, bowl {(f[rr, c] - z[rr, c]) * 3.28084:5.1f} ft")
    return p


def add_to_manifest(regions, built):
    mp = ROOT / "packs/manifest.json"
    m = json.loads(mp.read_text())
    m["packs"] = [p for p in m["packs"] if p.get("kind") != "region"]
    for r in regions:
        p = OUT / f"{r['id']}_grid.bin"
        if not p.exists():
            continue
        m["packs"].append({
            "id": f"region-{r['id']}", "kind": "region", "version": 1,
            "title": f"{r['name']}, {r['state']}: ground + bowls (10 m)",
            "summary": r["why"] + " Adds ground height offline and how deep water can stand at each spot (behind levees, the basin depth).",
            "bbox": r["bbox"], "hazards": r["hazards"],
            "files": [{"name": p.name, "url": f"{REL}/{p.name}", "bytes": p.stat().st_size, "sha256": sha(p)}],
            "total_bytes": p.stat().st_size, "license": "Public domain (USGS 3DEP)",
            "source": "https://github.com/craigm26/waterline (scripts/build_regions.py)"})
    mp.write_text(json.dumps(m, indent=1))
    print(f"manifest: {sum(p.get('kind') == 'region' for p in m['packs'])} region packs")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    regions = json.loads((ROOT / "regions/regions.json").read_text())["regions"]
    built = [build(r, a.check) for r in regions if not a.only or r["id"] in a.only]
    add_to_manifest(regions, built)


if __name__ == "__main__":
    main()
