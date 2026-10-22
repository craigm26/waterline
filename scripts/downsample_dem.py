#!/usr/bin/env python3
"""Mosaic the citywide 1 m DEM tiles into one 5 m GeoTIFF using decimated windowed reads (low memory).

    .venv\\Scripts\\python scripts\\downsample_dem.py [--res 5]
Input:  data/raw/citywide/dem/*.tif      Output: data/terrain/sf_dem_5m.tif (committed, ~15-30 MB)
"""
import argparse
import glob
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent


def main():
    import rasterio
    from rasterio.enums import Resampling
    from rasterio.transform import from_origin
    from pyproj import Transformer
    ap = argparse.ArgumentParser(); ap.add_argument("--res", type=float, default=5.0); a = ap.parse_args()
    paths = sorted(glob.glob(str(ROOT / "data/raw/citywide/dem/*.tif")))
    if not paths:
        raise SystemExit("no tiles: run download_citywide.py --only dem")
    with rasterio.open(paths[0]) as s0:
        crs = s0.crs
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    x0, y0 = tr.transform(-122.5155, 37.7080); x1, y1 = tr.transform(-122.3550, 37.8325)
    x0, y1 = np.floor(x0 / a.res) * a.res, np.ceil(y1 / a.res) * a.res
    W, H = int(np.ceil((x1 - x0) / a.res)), int(np.ceil((y1 - y0) / a.res))
    out = np.full((H, W), np.nan, dtype="float32")
    T = from_origin(x0, y1, a.res, a.res)
    for p in paths:
        with rasterio.open(p) as s:
            b = s.bounds
            c0, r0 = int((b.left - x0) / a.res), int((y1 - b.top) / a.res)
            w, h = int(round((b.right - b.left) / a.res)), int(round((b.top - b.bottom) / a.res))
            arr = s.read(1, out_shape=(h, w), resampling=Resampling.average, masked=True).filled(np.nan).astype("float32")
            rs, cs = max(0, -r0), max(0, -c0)
            re, ce = min(h, H - r0), min(w, W - c0)
            if re <= rs or ce <= cs:
                continue
            dst = out[r0 + rs:r0 + re, c0 + cs:c0 + ce]
            src = arr[rs:re, cs:ce]
            np.copyto(dst, src, where=~np.isnan(src))
            print(f"  {Path(p).name}: {w}x{h} cells")
    prof = {"driver": "GTiff", "height": H, "width": W, "count": 1, "dtype": "float32", "crs": crs, "transform": T,
            "compress": "deflate", "predictor": 3, "nodata": np.nan, "tiled": True}
    dst = ROOT / "data/terrain/sf_dem_5m.tif"
    with rasterio.open(dst, "w", **prof) as d:
        d.write(out, 1)
    print(f"wrote {dst.relative_to(ROOT)}: {W}x{H} at {a.res} m, {dst.stat().st_size/1e6:.1f} MB, "
          f"{np.isnan(out).mean()*100:.0f}% nodata")


if __name__ == "__main__":
    main()
