"""Build the downloadable data packs for the iOS app and write packs/manifest.json.

Packs (published as assets of GitHub release `packs-v1`; the app reads packs/manifest.json from main):
  sf-ground-1m   1 m lidar ground for low-lying SF (land <= 30 ft MLLW), 500 m tiles, used offline by the app
  sf-lidar-scenes  point clouds of the Ferry Building and five flood hotspots, viewable in the app (3D + water level)
  raw-laz        the same places as LAZ (open in any lidar viewer through the Files app)
  raw-dem        GeoTIFFs: 5 m citywide, 1 m Ferry Building and 17th & Folsom
  raw-dem-1m     the four citywide USGS 1 m DEM tiles (510 MB), straight from release data-v1

sf_ground_1m.bin layout: one JSON header line, then the tiles back to back. Each tile is
raw-deflate(int16 little-endian, cm NAVD88, -32768 = no data), rows north to south.

Usage:
  python scripts/build_packs.py --dem1m DIR [--out dist/packs]      # DIR holds the four USGS 1 m tiles (gh release data-v1)
  python scripts/build_packs.py --manifest-only                      # re-hash existing dist/packs
"""
import argparse, hashlib, json, shutil, zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
REL = "https://github.com/craigm26/waterline/releases/download"
TAG = "packs-v1"
TILE = 500                       # metres
LOW_NAVD_M = (30 + 0.06) / 3.28084   # 30 ft MLLW in m NAVD88 (ft MLLW = ft NAVD88 - 0.06)
SCENES = ["coast_scene", "hs01_soma", "hs02_folsom", "hs03_greathwy", "hs04_islais", "hs07_bayview"]


def deflate(b):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(b) + c.flush()


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ground_1m(dem_dir: Path, out: Path):
    import rasterio
    from rasterio.windows import from_bounds
    with rasterio.open(ROOT / "data/terrain/sf_dem_5m.tif") as s5:
        z5 = s5.read(1); T5 = s5.transform
        left, bottom, right, top = s5.bounds
    srcs = [rasterio.open(p) for p in sorted(dem_dir.glob("USGS_1M_*.tif"))]
    x0 = int(left // TILE) * TILE; y1 = int(-(-top // TILE)) * TILE
    nx = int(-(-(right - x0) // TILE)); ny = int(-(-(y1 - bottom) // TILE))
    tiles, blobs, off = [], [], 0
    for ty in range(ny):
        for tx in range(nx):
            tl, tt = x0 + tx * TILE, y1 - ty * TILE
            # SF land mask for this tile from the 5 m grid (no data = water or outside SF)
            c0 = int((tl - T5.c) / 5); r0 = int((T5.f - tt) / 5)
            m5 = np.full((TILE // 5, TILE // 5), np.nan, dtype="float32")
            rs, cs = max(0, r0), max(0, c0)
            re, ce = min(z5.shape[0], r0 + TILE // 5), min(z5.shape[1], c0 + TILE // 5)
            if re <= rs or ce <= cs:
                continue
            m5[rs - r0:re - r0, cs - c0:ce - c0] = z5[rs:re, cs:ce]
            land5 = ~np.isnan(m5)
            if not land5.any() or np.nanmin(m5) > LOW_NAVD_M:
                continue
            src = next(s for s in srcs if s.bounds.left <= tl + 1 and s.bounds.right >= tl + TILE - 1
                       and s.bounds.bottom <= tt - TILE + 1 and s.bounds.top >= tt - 1)
            win = from_bounds(tl, tt - TILE, tl + TILE, tt, src.transform).round_offsets().round_lengths()
            z = src.read(1, window=win, boundless=True, fill_value=src.nodata).astype("float64")[:TILE, :TILE]
            z[(z <= -9999) | np.isnan(z)] = np.nan
            land = np.kron(land5, np.ones((5, 5), dtype=bool))
            z[~land] = np.nan
            cm = np.where(np.isnan(z), -32768, np.clip(np.round(z * 100), -32767, 32767)).astype("<i2")
            blob = deflate(cm.tobytes())
            tiles.append({"tx": tx, "ty": ty, "offset": off, "bytes": len(blob)})
            blobs.append(blob); off += len(blob)
    hdr = {"schema": "waterline.ground1m.v1", "crs": "EPSG:26910", "x0": x0, "y0": y1, "tile_m": TILE, "res_m": 1,
           "nx": nx, "ny": ny, "dtype": "int16le", "unit": "cm NAVD88", "nodata": -32768, "compression": "raw deflate",
           "selection": "500 m tiles containing SF land at or below 30 ft MLLW; cells outside SF land are no data",
           "source": "USGS 3DEP 1 m DEM, CA_SanFrancisco_B23 (2023)", "tiles": tiles}
    p = out / "sf_ground_1m.bin"
    with open(p, "wb") as f:
        f.write(json.dumps(hdr, separators=(",", ":")).encode() + b"\n")
        for b in blobs:
            f.write(b)
    for s in srcs:
        s.close()
    print(f"sf_ground_1m.bin: {len(tiles)} tiles of {nx * ny}, {p.stat().st_size / 1e6:.1f} MB")
    return p


def check_1m(p: Path):
    from pyproj import Transformer
    raw = p.read_bytes(); i = raw.index(b"\n"); h = json.loads(raw[:i]); base = i + 1
    idx = {(t["tx"], t["ty"]): t for t in h["tiles"]}
    tr = Transformer.from_crs("EPSG:4326", "EPSG:26910", always_xy=True)
    for name, lon, lat in [("Ferry Building front plaza", -122.3935, 37.7955), ("SoMa by Mission Creek", -122.39824, 37.774407),
                           ("17th & Folsom", -122.4148, 37.7633), ("Marina Green", -122.4381, 37.8063)]:
        x, y = tr.transform(lon, lat)
        tx, ty = int((x - h["x0"]) // h["tile_m"]), int((h["y0"] - y) // h["tile_m"])
        t = idx.get((tx, ty))
        if not t:
            print(f"{name:28s} not in pack (tile above 30 ft)"); continue
        a = np.frombuffer(zlib.decompress(raw[base + t["offset"]: base + t["offset"] + t["bytes"]], -15), "<i2").reshape(h["tile_m"], h["tile_m"])
        c = int(x - h["x0"] - tx * h["tile_m"]); r = int(h["y0"] - ty * h["tile_m"] - y)
        v = a[r, c]
        print(f"{name:28s} " + ("no data" if v == -32768 else f"{v / 100 * 3.28084:.2f} ft NAVD88 = {v / 100 * 3.28084 - 0.06:.2f} ft MLLW"))


def pack_files(out: Path):
    """Copy the other packs' files into out/ and return the pack definitions."""
    L, T = ROOT / "data/lidar", ROOT / "data/terrain"
    defs = {
        "sf-lidar-scenes": [L / f"{n}.{e}" for n in SCENES for e in ("bin", "json")],
        "raw-laz": [L / f"{n}.laz" for n in SCENES] + [L / "coast_edge.laz", L / "rain_xsec.laz", L / "rain_scene.laz"],
        "raw-dem": [T / "sf_dem_5m.tif", T / "coast_dem_1m.tif", T / "rain_dem_1m.tif"],
    }
    for files in defs.values():
        for f in files:
            shutil.copy2(f, out / f.name)
    return {k: [f.name for f in v] for k, v in defs.items()}


def manifest(out: Path, defs, dem_dir: Path | None):
    def entry(name, url=None, path=None):
        p = path or out / name
        return {"name": name, "url": url or f"{REL}/{TAG}/{name}", "bytes": p.stat().st_size, "sha256": sha(p)}
    packs = [
        {"id": "sf-ground-1m", "kind": "ground1m", "version": 1, "title": "SF ground, 1 m lidar (low-lying areas)",
         "summary": "Ground height to the inch, offline, everywhere in San Francisco that sits 30 ft or less above the Bay. The app uses it in place of the 5 m grid.",
         "files": [entry("sf_ground_1m.bin")]},
        {"id": "sf-lidar-scenes", "kind": "scenes", "version": 1, "title": "Lidar point clouds: Ferry Building + 5 flood hotspots",
         "summary": "The USGS point clouds behind the city analysis. Open them in the app to orbit the block and raise the water.",
         "files": [entry(n) for n in defs["sf-lidar-scenes"]]},
        {"id": "raw-laz", "kind": "raw", "version": 1, "title": "Raw lidar (LAZ)",
         "summary": "The same places as standard LAZ point clouds, for any lidar app. Saved to Files › On My iPhone › Waterline.",
         "files": [entry(n) for n in defs["raw-laz"]]},
        {"id": "raw-dem", "kind": "raw", "version": 1, "title": "Elevation models (GeoTIFF)",
         "summary": "5 m citywide DEM, plus 1 m DEMs of the Ferry Building and 17th & Folsom. Ft = m × 3.28084; heights are NAVD88.",
         "files": [entry(n) for n in defs["raw-dem"]]},
    ]
    if dem_dir:
        packs.append({"id": "raw-dem-1m", "kind": "raw", "version": 1, "title": "Citywide 1 m DEM tiles (510 MB)",
                      "summary": "The four USGS 1 m tiles that cover San Francisco. Large: use Wi-Fi.",
                      "files": [entry(p.name, url=f"{REL}/data-v1/{p.name}", path=p) for p in sorted(dem_dir.glob("USGS_1M_*.tif"))]})
    for p in packs:
        p["total_bytes"] = sum(f["bytes"] for f in p["files"])
        p["license"] = "Public domain (USGS 3DEP)"
        p["source"] = "https://github.com/craigm26/waterline (scripts/build_packs.py)"
    m = {"schema": "waterline.packs.v1", "release": TAG, "packs": packs}
    (ROOT / "packs").mkdir(exist_ok=True)
    (ROOT / "packs/manifest.json").write_text(json.dumps(m, indent=1))
    for p in packs:
        print(f"{p['id']:16s} {len(p['files']):2d} files {p['total_bytes'] / 1e6:7.1f} MB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dem1m", type=Path)
    ap.add_argument("--out", type=Path, default=ROOT / "dist/packs")
    ap.add_argument("--manifest-only", action="store_true")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    if not a.manifest_only:
        p = ground_1m(a.dem1m, a.out)
        check_1m(p)
    defs = pack_files(a.out)
    manifest(a.out, defs, a.dem1m)


if __name__ == "__main__":
    main()
