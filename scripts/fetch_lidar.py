#!/usr/bin/env python3
"""Stream USGS 3DEP lidar POINT CLOUDS for the demo sites from the public AWS Entwine (EPT) index.

Source: s3://usgs-lidar-public/CA_SanFrancisco_1_B23  (USGS 3DEP, 2023; ~13 billion points)
Only the octree nodes that intersect each crop box are downloaded, so no 2 GB tile downloads.

Needs: numpy pyproj matplotlib "laspy[lazrs]"   (repo venv)
Usage:
    .venv\\Scripts\\python scripts\\fetch_lidar.py               # all crops
    .venv\\Scripts\\python scripts\\fetch_lidar.py --only coast_scene

Outputs (committed; sizes kept small by depth limits):
  data/lidar/{crop}.laz                   cropped points (EPSG:3857 XY, Z m NAVD88), all classes
  data/lidar/{crop}.bin + {crop}.json     Three.js-ready: float32 x,y,z (m, local UTM10N origin),
                                          uint8 class, uint8 intensity; JSON header with origin/CRS/counts
  assets/lidar/*.png                      oblique renders + street cross-section
  data/derived/lidar_checks.json          lidar ground vs DEM at named points; curb/crown/freeboard numbers
"""
from __future__ import annotations

import argparse
import io
import json
import math
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
EPT = "https://s3-us-west-2.amazonaws.com/usgs-lidar-public/CA_SanFrancisco_1_B23"
UA = {"User-Agent": "waterline-hackathon-prep/0.4"}
M_TO_FT = 3.28084
NAVD88_TO_MLLW_FT = 0.06

# crops: (lon, lat) center, half-size in metres, max EPT depth (deeper = denser)
CROPS = {
    "coast_scene": {"center": (-122.3935, 37.7955), "half_m": 220, "depth": 9,
                    "title": "Ferry Building & Embarcadero seawall"},
    "rain_scene": {"center": (-122.4150, 37.7634), "half_m": 180, "depth": 9,
                   "title": "17th & Folsom"},
    "rain_xsec": {"center": (-122.4150, 37.7631), "half_m": 30, "depth": 12,
                  "title": "Folsom St cross-section, just south of 17th"},
    "coast_edge": {"center": (-122.3933, 37.7957), "half_m": 30, "depth": 12,
                   "title": "Seawall edge in front of the Ferry Building"},
}
CLASS_RGB = {1: (150, 150, 150), 2: (176, 160, 140), 6: (214, 180, 120), 9: (47, 128, 193),
             3: (110, 160, 90), 4: (90, 150, 80), 5: (70, 130, 70), 17: (160, 120, 200)}


def get(url: str, timeout: int = 120) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read()


def to3857(lon, lat):
    x = math.radians(lon) * 6378137.0
    y = math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)) * 6378137.0
    return x, y


class Ept:
    def __init__(self):
        self.meta = json.loads(get(f"{EPT}/ept.json"))
        b = self.meta["bounds"]
        self.b = b
        self.w = b[3] - b[0]
        self._hier: dict[str, int] = {}
        self._load_hier("0-0-0-0")

    def _load_hier(self, key):
        h = json.loads(get(f"{EPT}/ept-hierarchy/{key}.json"))
        self._hier.update(h)

    def node_box(self, key):
        d, x, y, z = map(int, key.split("-"))
        w = self.w / (2 ** d)
        return (self.b[0] + x * w, self.b[1] + y * w, self.b[0] + (x + 1) * w, self.b[1] + (y + 1) * w)

    def nodes(self, box, max_depth):
        out, stack = [], ["0-0-0-0"]
        while stack:
            k = stack.pop()
            if k not in self._hier:
                continue
            if self._hier[k] == -1:
                self._load_hier(k)
                if self._hier.get(k, -1) == -1:
                    continue
            nb = self.node_box(k)
            if nb[2] < box[0] or nb[0] > box[2] or nb[3] < box[1] or nb[1] > box[3]:
                continue
            out.append(k)
            d, x, y, z = map(int, k.split("-"))
            if d < max_depth:
                for dx in (0, 1):
                    for dy in (0, 1):
                        for dz in (0, 1):
                            stack.append(f"{d+1}-{2*x+dx}-{2*y+dy}-{2*z+dz}")
        return out


def fetch_crop(ept: Ept, name: str, cfg: dict):
    import laspy
    lon, lat = cfg["center"]
    cx, cy = to3857(lon, lat)
    s = cfg["half_m"] / math.cos(math.radians(lat))  # 3857 metres are stretched by 1/cos(lat)
    box = (cx - s, cy - s, cx + s, cy + s)
    keys = ept.nodes(box, cfg["depth"])
    print(f"[{name}] {len(keys)} EPT nodes to depth {cfg['depth']}")

    def load(k):
        las = laspy.read(io.BytesIO(get(f"{EPT}/ept-data/{k}.laz")))
        m = (las.x >= box[0]) & (las.x <= box[2]) & (las.y >= box[1]) & (las.y <= box[3])
        return las.points[m] if m.any() else None, las.header

    with ThreadPoolExecutor(8) as ex:
        parts = list(ex.map(load, keys))
    pts = [p for p, _ in parts if p is not None]
    hdr = next(h for _, h in parts)
    if not pts:
        raise SystemExit(f"{name}: no points")
    out = laspy.LasData(laspy.LasHeader(point_format=hdr.point_format, version=hdr.version))
    out.header.scales, out.header.offsets = hdr.scales, hdr.offsets
    out.points = laspy.ScaleAwarePointRecord(np.concatenate([p.array for p in pts]), hdr.point_format,
                                             hdr.scales, hdr.offsets)
    p = ROOT / "data" / "lidar" / f"{name}.laz"
    p.parent.mkdir(parents=True, exist_ok=True)
    out.write(str(p))
    print(f"  {len(out.points):,} points -> {p.relative_to(ROOT)} ({p.stat().st_size/1e6:.1f} MB)")
    return out


def to_local(las):
    from pyproj import Transformer
    tr = Transformer.from_crs("EPSG:3857", "EPSG:26910", always_xy=True)
    e, n = tr.transform(np.asarray(las.x), np.asarray(las.y))
    return np.asarray(e), np.asarray(n), np.asarray(las.z, dtype="float64"), \
        np.asarray(las.classification, dtype="uint8"), np.asarray(las.intensity, dtype="float64")


def export_bin(name, las, cfg):
    e, n, z, c, it = to_local(las)
    o = (float(np.floor(e.mean())), float(np.floor(n.mean())))
    hi = np.percentile(it, 99) or 1
    arr = np.zeros(len(e), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("c", "u1"), ("i", "u1")])
    arr["x"], arr["y"], arr["z"], arr["c"] = e - o[0], n - o[1], z, c
    arr["i"] = np.clip(it / hi * 255, 0, 255).astype("u1")
    (ROOT / "data" / "lidar" / f"{name}.bin").write_bytes(arr.tobytes())
    classes = {int(k): int(v) for k, v in zip(*np.unique(c, return_counts=True))}
    json.dump({"title": cfg["title"], "points": int(len(e)), "stride_bytes": 14,
               "layout": "float32 x,y,z (m) | uint8 class | uint8 intensity (0-255, p99-scaled)",
               "origin_utm10n_nad83": o, "z": "metres NAVD88 (USGS 3DEP)", "classes": classes,
               "asprs_classes": {"1": "unclassified (includes buildings in this survey)", "2": "ground", "6": "building", "9": "water",
                                 "17": "bridge deck", "3-5": "vegetation", "7/18": "noise"},
               "source": "USGS 3DEP CA_SanFrancisco_1_B23 via AWS EPT", "provenance": "official"},
              open(ROOT / "data" / "lidar" / f"{name}.json", "w"), indent=1)
    print(f"  three.js bin: {len(e):,} pts, classes {classes}")


def _render(name, las, cfg, water_levels_ft=None, out_png=None, az_deg=225, elev_deg=35):
    """Oblique point render with a simple z-buffer. Points at/below a water level are tinted."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    e, n, z, c, it = to_local(las)
    keep = ~np.isin(c, [7, 18])
    e, n, z, c, it = e[keep], n[keep], z[keep], c[keep], it[keep]
    e -= e.mean(); n -= n.mean()
    a, el = math.radians(az_deg), math.radians(elev_deg)
    xr = e * math.cos(a) - n * math.sin(a)
    yr = e * math.sin(a) + n * math.cos(a)
    sx = xr
    sy = z * math.cos(el) * 2.0 + yr * math.sin(el)   # 2x vertical exaggeration
    depth = -yr * math.cos(el) + z * math.sin(el)
    W, H = 1920, 1080
    pad = 0.04
    x0, x1, y0, y1 = sx.min(), sx.max(), sy.min(), sy.max()
    sc = min(W * (1 - 2 * pad) / (x1 - x0), H * (1 - 2 * pad) / (y1 - y0))
    px = ((sx - x0) * sc + W * pad + (W * (1 - 2 * pad) - (x1 - x0) * sc) / 2).astype(int)
    py = (H - ((sy - y0) * sc + H * pad + (H * (1 - 2 * pad) - (y1 - y0) * sc) / 2)).astype(int)
    shade = np.clip(it / (np.percentile(it, 98) or 1), 0, 1) * 0.5 + 0.5
    rgb = np.array([CLASS_RGB.get(int(k), (140, 140, 140)) for k in c], dtype="float64") / 255.0
    rgb *= shade[:, None]
    if water_levels_ft is not None:
        wl_m = (water_levels_ft - NAVD88_TO_MLLW_FT) / M_TO_FT
        wet = (z <= wl_m) & np.isin(c, [1, 2, 9])
        rgb[wet] = rgb[wet] * 0.35 + np.array([0.18, 0.50, 0.76]) * 0.65
    img = np.ones((H, W, 3))
    zb = np.full((H, W), -np.inf)
    order = np.argsort(depth)
    for dx in (0, 1):
        for dy in (0, 1):
            qx, qy = np.clip(px[order] + dx, 0, W - 1), np.clip(py[order] + dy, 0, H - 1)
            img[qy, qx] = rgb[order]
    fig = plt.figure(figsize=(16, 9), dpi=120)
    ax = fig.add_axes([0, 0, 1, 1]); ax.imshow(img); ax.axis("off")
    ax.text(30, 60, cfg["title"], fontsize=26, weight="bold", color="#1f2933")
    sub = "USGS 3DEP lidar (2023), {:,} points, 2× vertical exaggeration".format(len(z))
    if water_levels_ft is not None:
        sub += f". Blue = ground/water points at or below {water_levels_ft:.1f} ft MLLW (elevation only, not a flood model)"
    ax.text(30, 100, sub, fontsize=14, color="#3e4c59")
    p = ROOT / "assets" / "lidar" / (out_png or f"{name}.png")
    p.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(p); plt.close(fig)
    print(f"  render {p.relative_to(ROOT)}")


def xsec(name, las, cfg, axis="ew", band_m=1.0):
    """Street cross-section from ground + unclassified points in a thin band."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    e, n, z, c, _ = to_local(las)
    from pyproj import Transformer
    ce, cn = Transformer.from_crs("EPSG:4326", "EPSG:26910", always_xy=True).transform(*cfg["center"])
    along, across = (e - ce, n - cn) if axis == "ew" else (n - cn, e - ce)
    m = (np.abs(across) <= band_m) & (c == 2) & (np.abs(along) <= cfg["half_m"])
    a, zz = along[m], z[m] * M_TO_FT
    bins = np.arange(-cfg["half_m"], cfg["half_m"] + 0.25, 0.25)
    idx = np.digitize(a, bins)
    prof = np.array([[bins[i - 1] + 0.125, np.percentile(zz[idx == i], 20)] for i in np.unique(idx)
                     if (idx == i).sum() >= 3 and 0 < i < len(bins)])
    road = prof[np.abs(prof[:, 0]) <= 5][:, 1]
    crown = float(np.max(road)) if len(road) else float("nan")
    gutter = float(np.min(prof[np.abs(prof[:, 0]) <= 13][:, 1]))
    walk = prof[(np.abs(prof[:, 0]) >= 14) & (np.abs(prof[:, 0]) <= 17)][:, 1]
    sidewalk = float(np.median(walk)) if len(walk) else float("nan")
    res = {"crown_ft_navd88": round(crown, 2), "gutter_ft_navd88": round(gutter, 2),
           "sidewalk_ft_navd88": round(sidewalk, 2),
           "curb_height_in": round((sidewalk - gutter) * 12, 1),
           "water_depth_at_gutter_to_top_curb_in": round((sidewalk - gutter) * 12, 1),
           "points_used": int(m.sum())}
    fig, ax = plt.subplots(figsize=(16, 9), dpi=120)
    fig.subplots_adjust(left=0.07, right=0.97, top=0.80, bottom=0.14)
    ax.scatter(a, zz, s=2, color="#9aa5b1", alpha=0.5, label="lidar ground points (±1 m band)")
    ax.plot(prof[:, 0], prof[:, 1], color="#1f2933", lw=2.5, label="surface profile (20th pct, 25 cm bins)")
    if not math.isnan(sidewalk):
        ax.fill_between(prof[:, 0], prof[:, 1], np.minimum(sidewalk, prof[:, 1].max()),
                        where=prof[:, 1] < sidewalk, color="#2f80c1", alpha=0.35, label="water up to curb top")
        ax.axhline(sidewalk, color="#2f80c1", lw=1.2, ls="--")
    ax.set_xlabel("Distance across the street (m, west → east)" if axis == "ew" else "Distance (m)")
    ax.set_ylabel("Elevation (ft NAVD88)")
    ax.spines[["top", "right"]].set_visible(False)
    ax.grid(color="#e4e7eb")
    ax.legend(frameon=False, loc="lower left", fontsize=12)
    fig.suptitle(cfg["title"], x=0.07, ha="left", y=0.95, fontsize=24, weight="bold", color="#1f2933")
    fig.text(0.07, 0.86, f"Curb height ≈ {res['curb_height_in']} in. Water in the gutter deeper than that "
             f"reaches sidewalks and doorways.  Crown {crown:.1f} ft · gutter {gutter:.1f} ft · sidewalk {sidewalk:.1f} ft NAVD88",
             fontsize=14, color="#1f2933")
    fig.text(0.07, 0.03, "USGS 3DEP lidar CA_SanFrancisco_1_B23 (2023), ground class only. "
             "Measured, not modeled.", fontsize=11, color="#7b8794")
    p = ROOT / "assets" / "lidar" / f"{name}.png"
    p.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(p); plt.close(fig)
    print(f"  cross-section {p.relative_to(ROOT)}: {res}")
    return res


def dem_check(las, points):
    """Compare lidar ground (class 2) to the bare-earth DEM elevations staged earlier."""
    from pyproj import Transformer
    e, n, z, c, _ = to_local(las)
    g = c == 2
    tr = Transformer.from_crs("EPSG:4326", "EPSG:26910", always_xy=True)
    out = {}
    for k, (lat, lon, dem_ft) in points.items():
        pe, pn = tr.transform(lon, lat)
        m = g & (np.hypot(e - pe, n - pn) <= 1.5)
        if m.sum():
            out[k] = {"lidar_ground_ft": round(float(np.median(z[m])) * M_TO_FT, 2), "dem_ft": dem_ft,
                      "n": int(m.sum())}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", choices=list(CROPS))
    a = ap.parse_args()
    ept = Ept()
    print(f"EPT: {ept.meta['points']:,} points, srs EPSG:{ept.meta['srs'].get('horizontal')}")
    checks = {}
    try:
        stack = json.load(open(ROOT / "data" / "derived" / "coastal_stack.json"))
    except FileNotFoundError:
        stack = None
    spots = {}
    try:
        spots = json.load(open(ROOT / "data" / "raw" / "spot_elevations_navd88_ft.json"))
    except FileNotFoundError:
        pass
    for name in a.only or CROPS:
        cfg = CROPS[name]
        las = fetch_crop(ept, name, cfg)
        if name.endswith("_scene"):
            export_bin(name, las, cfg)
            _render(name, las, cfg)
            if name == "coast_scene" and stack:
                for lab, lv, _ in stack["scenarios"]:
                    tag = lab.split("(")[0].strip().lower().replace("+ ", "plus_").replace(" ", "_")
                    _render(name, las, cfg, water_levels_ft=lv, out_png=f"coast_scene_{tag}.png")
            if name == "coast_scene":
                checks["dem_vs_lidar_coast"] = dem_check(las, {
                    "Ferry Bldg front plaza": (37.7953, -122.3940, spots.get("Ferry Bldg front plaza")),
                    "Embarcadero at Market": (37.7946, -122.3950, spots.get("Embarcadero roadway at Market")),
                    "Ferry Plaza bayside": (37.7958, -122.3925, spots.get("Ferry Plaza bayside"))})
            if name == "rain_scene":
                checks["dem_vs_lidar_rain"] = dem_check(las, {
                    "17th & Folsom": (37.7634, -122.4150, spots.get("17th & Folsom"))})
        elif name == "rain_xsec":
            checks["folsom_xsec"] = xsec(name, las, cfg, axis="ew")
        elif name == "coast_edge":
            e, n, z, c, _ = to_local(las)
            gz = z[c == 2] * M_TO_FT
            wz = z[c == 9] * M_TO_FT
            checks["seawall_edge"] = {"ground_p95_ft_navd88": round(float(np.percentile(gz, 95)), 2),
                                      "ground_p50_ft_navd88": round(float(np.percentile(gz, 50)), 2),
                                      "water_class_points": int((c == 9).sum()),
                                      "water_surface_at_flight_ft_navd88": round(float(np.median(wz)), 2) if len(wz) else None,
                                      "note": "class 2 = ground; this survey leaves buildings unclassified (class 1)"}
            print(f"  seawall edge: {checks['seawall_edge']}")
    p = ROOT / "data" / "derived" / "lidar_checks.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    old = json.load(open(p)) if p.exists() else {}
    old.update(checks)
    json.dump(old, open(p, "w"), indent=1)
    print("Done.", json.dumps(checks, indent=1))


if __name__ == "__main__":
    sys.exit(main())
