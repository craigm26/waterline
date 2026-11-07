"""Give every region the datasets San Francisco has. Run on a machine with a good connection:
everything streams from the public sources, and only the results are kept. Every step skips
what's already built, so an interrupted run just continues.

  ground   <id>_ground_1m.bin   1 m ground for land at or below 30 ft NAVD88, same layout as sf_ground_1m.bin
  scenes   <scene>.bin/.json    point clouds of a landmark and the top 5 low spots, for the app's 3D view
           <scene>.laz          the same points as LAZ
  dem      <id>_dem_10m.tif     citywide 10 m DEM; <scene>_dem_1m.tif for the landmark and top low spot
  manifest                      packs/manifest.json: one group per place, every pack tagged with its group

Usage: python scripts/build_region_packs.py ground scenes dem manifest [--only sacramento] [--workers 6]
Needs dist/regions/<id>_grid.bin and <id>_layers.json (build_regions.py, build_region_layers.py).
"""
import argparse, hashlib, io, json, math, os, time, urllib.parse, urllib.request, zlib
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "dist/regions"
REL = "https://github.com/craigm26/waterline/releases/download/packs-v1"
UA = {"User-Agent": "waterline-data-build (https://github.com/craigm26/waterline)"}
TILE = 500
LOW_NAVD_M = 30 / 3.28084
EPT_INDEX = "https://raw.githubusercontent.com/hobu/usgs-lidar/master/boundaries/resources.geojson"
USGS_DOWNLOADER = "https://apps.nationalmap.gov/downloader/"
GDAL = dict(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif",
            GDAL_HTTP_MAX_RETRY="5", GDAL_HTTP_RETRY_DELAY="3", GDAL_CACHEMAX="256", VSI_CACHE="TRUE")


def get(url, timeout=120, tries=5):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
                return r.read()
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(3 * (i + 1))


def deflate(b):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(b) + c.flush()


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for ch in iter(lambda: f.read(1 << 20), b""):
            h.update(ch)
    return h.hexdigest()


def read_grid(rid):
    raw = (OUT / f"{rid}_grid.bin").read_bytes(); i = raw.index(b"\n"); h = json.loads(raw[:i]); o = i + 1
    g = np.frombuffer(zlib.decompress(raw[o:o + h["ground"]["bytes"]], -15), "<i2").reshape(h["rows"], h["cols"]).astype("float32")
    g[g == h["nodata_ground"]] = np.nan
    return g / 100, h


def dem_items(r):
    """USGS 1 m DEM tiles over the region, oldest first so newer surveys overwrite older ones."""
    w, s, e, n = r["bbox"]
    q = urllib.parse.urlencode({"datasets": "Digital Elevation Model (DEM) 1 meter", "bbox": f"{w},{s},{e},{n}", "max": 500, "outputFormat": "JSON"})
    d = json.loads(get(f"https://tnmaccess.nationalmap.gov/api/v1/products?{q}", 90))
    it = [{"url": i["downloadURL"], "date": i.get("publicationDate") or "", "bytes": i.get("sizeInBytes") or 0,
           "box": [i["boundingBox"][k] for k in ("minX", "minY", "maxX", "maxY")]} for i in d["items"] if i["downloadURL"].endswith(".tif")]
    return sorted(it, key=lambda x: x["date"])


# ---- 1 m reads, shared by ground and dem ------------------------------------------------------
_open = {}


def read_1m(items, epsg, left, top, w, h):
    """w x h metres of 1 m ground in the region's UTM zone, mosaicked from the source tiles."""
    import rasterio
    from pyproj import Transformer
    from rasterio.enums import Resampling
    from rasterio.transform import from_origin
    from rasterio.vrt import WarpedVRT
    tr = Transformer.from_crs(epsg, 4326, always_xy=True)
    lons, lats = tr.transform([left, left + w, left, left + w], [top, top, top - h, top - h])
    box = (min(lons), min(lats), max(lons), max(lats))
    z = np.full((h, w), np.nan, dtype="float32")
    T = from_origin(left, top, 1, 1)
    hits = [i for i in items if i["box"][0] < box[2] and i["box"][2] > box[0] and i["box"][1] < box[3] and i["box"][3] > box[1]]
    with rasterio.Env(**GDAL):
        for it in reversed(hits):       # newest first; stop once the tile is full
            if not np.isnan(z).any():
                break
            url = "/vsicurl/" + it["url"]
            src = _open.get(url)
            if src is None:
                if len(_open) > 12:
                    _open.pop(next(iter(_open))).close()
                try:
                    src = _open[url] = rasterio.open(url)
                except Exception:
                    continue
            with WarpedVRT(src, crs=f"EPSG:{epsg}", transform=T, width=w, height=h, resampling=Resampling.bilinear,
                           src_nodata=src.nodata, nodata=np.nan, dtype="float32") as v:
                a = v.read(1)
            ok = np.isnan(z) & ~np.isnan(a) & (a > -1000)
            z[ok] = a[ok]
    return z


def one_tile(job):
    items, epsg, tx, ty, x0, y1, land = job
    z = read_1m(items, epsg, x0 + tx * TILE, y1 - ty * TILE, TILE, TILE)
    z[~np.kron(land, np.ones((10, 10), dtype=bool))] = np.nan
    if np.isnan(z).all():
        return tx, ty, None
    cm = np.where(np.isnan(z), -32768, np.clip(np.round(z * 100), -32767, 32767)).astype("<i2")
    return tx, ty, deflate(cm.tobytes())


def ground(r, workers):
    p = OUT / f"{r['id']}_ground_1m.bin"
    if p.exists():
        return
    z, h = read_grid(r["id"]); items = dem_items(r)
    res = h["res_m"]; n10 = int(TILE / res)
    x0 = int(h["x0"] // TILE) * TILE; y1 = -int(-h["y0"] // TILE) * TILE
    ox, oy = int((h["x0"] - x0) / res), int((y1 - h["y0"]) / res)
    nx = (ox + h["cols"]) // n10 + 1; ny = (oy + h["rows"]) // n10 + 1
    pad = np.full((ny * n10, nx * n10), np.nan, dtype="float32")
    pad[oy:oy + h["rows"], ox:ox + h["cols"]] = z
    jobs = []
    for ty in range(ny):
        for tx in range(nx):
            t = pad[ty * n10:(ty + 1) * n10, tx * n10:(tx + 1) * n10]
            land = ~np.isnan(t)
            if land.any() and np.nanmin(t) <= LOW_NAVD_M:
                jobs.append((items, r["epsg"], tx, ty, x0, y1, land))
    print(f"{r['id']}: {len(jobs)} of {nx * ny} tiles from {len(items)} USGS files", flush=True)
    tiles, blobs, off = [], [], 0
    t0 = time.time()
    with ProcessPoolExecutor(workers) as ex:
        for i, (tx, ty, b) in enumerate(ex.map(one_tile, jobs, chunksize=8), 1):
            if b is not None:
                tiles.append({"tx": tx, "ty": ty, "offset": off, "bytes": len(b)}); blobs.append(b); off += len(b)
            if i % 200 == 0:
                print(f"  {i}/{len(jobs)} {off / 1e6:.0f} MB {time.time() - t0:.0f}s", flush=True)
    hdr = {"schema": "waterline.ground1m.v1", "region": r["id"], "crs": f"EPSG:{r['epsg']}", "zone": r["epsg"] - 26900,
           "x0": x0, "y0": y1, "tile_m": TILE, "res_m": 1, "nx": nx, "ny": ny, "dtype": "int16le", "unit": "cm NAVD88",
           "nodata": -32768, "compression": "raw deflate", "selection": "500 m tiles with land at or below 30 ft NAVD88",
           "source": "USGS 3DEP 1 m DEM", "tiles": tiles}
    tmp = p.with_suffix(".tmp")
    with open(tmp, "wb") as f:
        f.write(json.dumps(hdr, separators=(",", ":")).encode() + b"\n")
        for b in blobs:
            f.write(b)
    tmp.rename(p)
    print(f"  -> {p.name} {p.stat().st_size / 1e6:.1f} MB", flush=True)


# ---- point clouds -----------------------------------------------------------------------------
def to3857(lon, lat):
    return math.radians(lon) * 6378137.0, math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)) * 6378137.0


class Ept:
    def __init__(self, url):
        self.base = url.rsplit("/", 1)[0]
        self.meta = json.loads(get(url))
        self.b = self.meta["bounds"]; self.w = self.b[3] - self.b[0]; self.hier = {}
        self.load("0-0-0-0")

    def load(self, k):
        self.hier.update(json.loads(get(f"{self.base}/ept-hierarchy/{k}.json")))

    def box(self, k):
        d, x, y, z = map(int, k.split("-")); w = self.w / 2 ** d
        return self.b[0] + x * w, self.b[1] + y * w, self.b[0] + (x + 1) * w, self.b[1] + (y + 1) * w

    def nodes(self, box, depth):
        out, stack = [], ["0-0-0-0"]
        while stack:
            k = stack.pop()
            if k not in self.hier:
                continue
            if self.hier[k] == -1:
                self.load(k)
                if self.hier.get(k, -1) == -1:
                    continue
            b = self.box(k)
            if b[2] < box[0] or b[0] > box[2] or b[3] < box[1] or b[1] > box[3]:
                continue
            out.append(k)
            d, x, y, z = map(int, k.split("-"))
            if d < depth:
                stack += [f"{d + 1}-{2 * x + i}-{2 * y + j}-{2 * z + m}" for i in (0, 1) for j in (0, 1) for m in (0, 1)]
        return out


def ept_candidates(lon, lat, index):
    from shapely.geometry import Point, shape
    pt = Point(lon, lat); out = []
    for f in index["features"]:
        if f.get("geometry") and shape(f["geometry"]).contains(pt):
            p = f["properties"]
            yrs = [int(t) for t in p["name"].replace("-", "_").split("_") if t.isdigit() and len(t) == 4]
            b = [t for t in p["name"].split("_") if t[:1] == "B" and t[1:].isdigit()]
            year = max(yrs, default=2000 + int(b[0][1:]) if b else 2000)
            out.append((year, p["count"], p["name"], p["url"]))
    return sorted(out, reverse=True)


def fetch_points(url, lon, lat, half_m, want=260_000):
    import laspy
    e = Ept(url)
    cx, cy = to3857(lon, lat); s = half_m / math.cos(math.radians(lat))
    box = (cx - s, cy - s, cx + s, cy + s)
    got, parts, hdr, total = set(), [], None, 0

    def load(k):
        las = laspy.read(io.BytesIO(get(f"{e.base}/ept-data/{k}.laz")))
        m = (las.x >= box[0]) & (las.x <= box[2]) & (las.y >= box[1]) & (las.y <= box[3])
        return (las.points[m] if m.any() else None), las.header

    for depth in range(6, 17):          # one octree level at a time until the crop is dense enough
        keys = [k for k in e.nodes(box, depth) if k not in got]
        if not keys and depth > 10:
            break
        with ThreadPoolExecutor(8) as ex:
            for pts, h in ex.map(load, keys):
                hdr = h
                if pts is not None:
                    parts.append(pts); total += len(pts)
        got.update(keys)
        if total >= want:
            break
    if not parts:
        return None
    las = laspy.LasData(laspy.LasHeader(point_format=hdr.point_format, version=hdr.version))
    las.header.scales, las.header.offsets = hdr.scales, hdr.offsets
    las.points = laspy.ScaleAwarePointRecord(np.concatenate([p.array for p in parts]), hdr.point_format, hdr.scales, hdr.offsets)
    return las


def grid_ground(z, h, epsg, lon, lat):
    from pyproj import Transformer
    x, y = Transformer.from_crs(4326, epsg, always_xy=True).transform(lon, lat)
    c, r = int((x - h["x0"]) / h["res_m"]), int((h["y0"] - y) / h["res_m"])
    k = 18
    a = z[max(0, r - k):r + k, max(0, c - k):c + k]
    return float(np.nanmedian(a)) if a.size and not np.isnan(a).all() else None


def scene_list(r):
    lay = json.loads((OUT / f"{r['id']}_layers.json").read_text())
    lm = r["landmark"]
    out = [{"stem": f"{r['id']}_landmark", "title": lm["name"], "lon": lm["lon"], "lat": lm["lat"]}]
    for s in lay["hotspots"][:5]:
        out.append({"stem": f"{r['id']}_ls{s['rank']:02d}", "title": f"Low spot #{s['rank']}: {s['name']}", "lon": s["lon"], "lat": s["lat"]})
    return out


def scenes(r, index):
    from pyproj import Transformer
    z, h = read_grid(r["id"])
    for s in scene_list(r):
        bin_p = OUT / f"{s['stem']}.bin"
        if bin_p.exists():
            continue
        ref = grid_ground(z, h, r["epsg"], s["lon"], s["lat"])
        las, used, shift = None, None, 0.0
        for year, count, name, url in ept_candidates(s["lon"], s["lat"], index):
            try:
                c = fetch_points(url, s["lon"], s["lat"], 180)
            except Exception as ex:
                print(f"  {s['stem']}: {name} failed: {ex}", flush=True); continue
            if c is None or len(c.points) < 20_000:
                continue
            g = np.asarray(c.z)[np.asarray(c.classification) == 2]
            if len(g) < 500:
                continue
            if ref is not None and abs(float(np.median(g)) - ref) > 60:
                print(f"  {s['stem']}: {name} ground {np.median(g):.1f} m vs grid {ref:.1f}: skipped", flush=True); continue
            las, used = c, name
            shift = 0.0 if ref is None or abs(float(np.median(g)) - ref) < 1.0 else ref - float(np.median(g))
            break
        if las is None:
            print(f"  {s['stem']}: NO LIDAR", flush=True); continue
        n = len(las.points)
        keep = np.sort(np.random.default_rng(1).choice(n, 330_000, replace=False)) if n > 330_000 else np.arange(n)
        xs, ys = np.asarray(las.x)[keep], np.asarray(las.y)[keep]
        e, nn = Transformer.from_crs(3857, r["epsg"], always_xy=True).transform(xs, ys)
        zz = np.asarray(las.z, "float64")[keep] + shift
        cl = np.asarray(las.classification, "uint8")[keep]
        it = np.asarray(las.intensity, "float64")[keep]
        o = (float(np.floor(e.mean())), float(np.floor(nn.mean())))
        hi = np.percentile(it, 99) or 1
        arr = np.zeros(len(e), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("c", "u1"), ("i", "u1")])
        arr["x"], arr["y"], arr["z"], arr["c"], arr["i"] = e - o[0], nn - o[1], zz, cl, np.clip(it / hi * 255, 0, 255).astype("u1")
        gz = zz[cl == 2]
        meta = {"title": s["title"], "lon": s["lon"], "lat": s["lat"], "points": int(len(e)), "stride_bytes": 14,
                "layout": "float32 x,y,z (m) | uint8 class | uint8 intensity (0-255, p99-scaled)", "origin_utm": o, "zone": r["epsg"] - 26900,
                "z": "metres NAVD88 (USGS 3DEP)", "ground_p5_m": round(float(np.percentile(gz, 5)), 2), "ground_p50_m": round(float(np.median(gz)), 2),
                "z_shift_m": round(shift, 2), "survey": used, "source": f"USGS 3DEP {used} via AWS EPT", "provenance": "official"}
        las.points = las.points[keep]
        las.write(str(OUT / f"{s['stem']}.laz"))
        (OUT / f"{s['stem']}.json").write_text(json.dumps(meta, indent=1))
        bin_p.write_bytes(arr.tobytes())   # last, so a partly written scene is rebuilt
        print(f"  {s['stem']}: {len(e):,} pts, {used}, z shift {shift:+.2f} m, ground {np.median(gz) * 3.28084:.1f} ft vs grid {(ref or 0) * 3.28084:.1f}", flush=True)


# ---- GeoTIFFs ---------------------------------------------------------------------------------
def dem(r):
    import rasterio
    from pyproj import Transformer
    from rasterio.transform import from_origin
    prof = dict(driver="GTiff", dtype="float32", count=1, nodata=-9999, compress="deflate", predictor=3, tiled=True,
                blockxsize=512, blockysize=512, crs=f"EPSG:{r['epsg']}")
    p = OUT / f"{r['id']}_dem_10m.tif"
    if not p.exists():
        z, h = read_grid(r["id"])
        with rasterio.open(p, "w", height=h["rows"], width=h["cols"], transform=from_origin(h["x0"], h["y0"], h["res_m"], h["res_m"]), **prof) as d:
            d.write(np.nan_to_num(z, nan=-9999), 1)
        print(f"  {p.name} {p.stat().st_size / 1e6:.1f} MB", flush=True)
    items = dem_items(r)
    tr = Transformer.from_crs(4326, r["epsg"], always_xy=True)
    for s in scene_list(r)[:2]:
        p = OUT / f"{s['stem']}_dem_1m.tif"
        if p.exists():
            continue
        x, y = tr.transform(s["lon"], s["lat"]); left, top = int(x) - 500, int(y) + 500
        a = read_1m(items, r["epsg"], left, top, 1000, 1000)
        with rasterio.open(p, "w", height=1000, width=1000, transform=from_origin(left, top, 1, 1), **prof) as d:
            d.write(np.nan_to_num(a, nan=-9999), 1)
        print(f"  {p.name} {p.stat().st_size / 1e6:.1f} MB", flush=True)


# ---- manifest ---------------------------------------------------------------------------------
SF_LABELS = {"sf-ground-1m": "Ground, 1 m lidar (low-lying areas)", "sf-lidar-scenes": "Lidar point clouds: Ferry Building + 5 low spots",
             "raw-laz": "Raw lidar (LAZ)", "raw-dem": "Elevation models (GeoTIFF)", "raw-dem-1m": "Citywide 1 m DEM tiles"}


def manifest(regions):
    mp = ROOT / "packs/manifest.json"
    m = json.loads(mp.read_text())
    m["packs"] = [p for p in m["packs"] if p["kind"] != "layers" and not p.get("group", "").startswith("r:") and (p["id"].startswith(("sf-", "raw-")) or p["kind"] == "region")]
    for p in m["packs"]:
        if p["kind"] != "region":
            p["group"], p["label"] = "san-francisco", SF_LABELS[p["id"]]
    groups = [{"id": "san-francisco", "name": "San Francisco", "state": "CA", "bbox": [-122.53, 37.703, -122.355, 37.835], "bundled": True}]
    lic_usgs = "Public domain (USGS 3DEP)"
    city = json.loads((ROOT / "regions/city_sources.json").read_text())

    def file(name):
        p = OUT / name
        return {"name": name, "url": f"{REL}/{name}", "bytes": p.stat().st_size, "sha256": sha(p)}

    def add(r, pid, kind, label, summary, names, lic=lic_usgs):
        names = [n for n in names if (OUT / n).exists()]
        if not names:
            return
        fs = [file(n) for n in names]
        m["packs"].append({"id": pid, "kind": kind, "version": 1, "group": r["id"], "label": label, "title": f"{r['name']}: {label}", "summary": summary,
                           "bbox": r["bbox"], "files": fs, "total_bytes": sum(f["bytes"] for f in fs), "license": lic,
                           "source": "https://github.com/craigm26/waterline (scripts/build_region_packs.py)"})

    for r in regions:
        rid = r["id"]
        for p in m["packs"]:
            if p["id"] == f"region-{rid}":
                p["group"], p["label"] = rid, "Ground and bowls, 10 m"
        items = dem_items(r)
        groups.append({"id": rid, "name": r["name"], "state": r["state"], "bbox": r["bbox"], "hazards": r["hazards"], "why": r["why"], "caveat": r.get("caveat"), "live": city.get(rid),
                       "usgs_1m": {"url": USGS_DOWNLOADER, "tiles": len(items), "bytes": sum(i["bytes"] for i in items)}})
        stems = [s["stem"] for s in scene_list(r)]
        lay = json.loads((OUT / f"{rid}_layers.json").read_text())
        have = "FEMA flood zones, levees and floodwalls, and mapped low spots"
        add(r, f"{rid}-layers", "layers", "Map and AR layers", f"{have}. Shows on the Map and as tags in the camera view. City drains and service requests load live when you're online.",
            [f"{rid}_layers.json"], "FEMA, USACE and city open data; names (c) OpenStreetMap contributors")
        add(r, f"{rid}-ground-1m", "ground1m", "Ground, 1 m lidar (low-lying areas)", "Ground height to the inch, offline, for land at or below 30 ft. The app uses it in place of the 10 m grid.", [f"{rid}_ground_1m.bin"])
        add(r, f"{rid}-scenes", "scenes", f"Lidar point clouds: {r['landmark']['name']} + 5 low spots", "Open them in the app to orbit the block and raise the water.",
            [f"{s}.{e}" for s in stems for e in ("bin", "json")])
        add(r, f"{rid}-laz", "raw", "Raw lidar (LAZ)", "The same places as standard LAZ point clouds, for any lidar app. Saved to Files › On My iPhone › Waterline.", [f"{s}.laz" for s in stems])
        add(r, f"{rid}-dem", "raw", "Elevation models (GeoTIFF)", "10 m citywide DEM, plus 1 m DEMs of the landmark and top low spot. Heights are NAVD88.",
            [f"{rid}_dem_10m.tif"] + [f"{s}_dem_1m.tif" for s in stems[:2]])
    m["groups"] = groups
    mp.write_text(json.dumps(m, indent=1))
    print(f"manifest: {len(groups)} groups, {len(m['packs'])} packs, {sum(p['total_bytes'] for p in m['packs']) / 1e9:.2f} GB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("steps", nargs="+", choices=["ground", "scenes", "dem", "manifest"])
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args()
    regions = json.loads((ROOT / "regions/regions.json").read_text())["regions"]
    todo = [r for r in regions if not a.only or r["id"] in a.only]
    index = json.loads(get(EPT_INDEX)) if "scenes" in a.steps else None
    for s in a.steps:
        if s == "manifest":
            manifest(regions); continue
        for r in todo:
            print(f"== {s} {r['id']}", flush=True)
            try:
                {"ground": lambda: ground(r, a.workers), "scenes": lambda: scenes(r, index), "dem": lambda: dem(r)}[s]()
            except Exception as ex:      # one region's failure shouldn't stop the rest; a rerun retries it
                print(f"FAILED {s} {r['id']}: {ex!r}", flush=True)


if __name__ == "__main__":
    main()
