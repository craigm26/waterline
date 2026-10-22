#!/usr/bin/env python3
"""Pack the derived data the story site needs into demo/story-data.json (no network).

Run after build_assets.py / fetch_lidar.py / drain_priority.py:
    python scripts/build_story_data.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "data" / "derived"


def rj(p):
    return json.loads(Path(p).read_text(encoding="utf-8-sig"))


HOTSPOT_SCENES = [("hs02_folsom", "14th–15th & Folsom, Mission"), ("hs01_soma", "SoMa by Mission Creek"),
                  ("hs04_islais", "Islais Creek / Dogpatch"), ("hs07_bayview", "Bayview, 3rd St"),
                  ("hs03_greathwy", "Lower Great Highway, Outer Sunset")]


def citywide():
    """Basemap PNG + everything projected to its pixel grid (no reprojection needed in the browser)."""
    import csv
    import numpy as np
    import rasterio
    from PIL import Image
    from pyproj import Transformer
    with rasterio.open(ROOT / "data/terrain/sf_dem_5m.tif") as s:
        z = s.read(1).astype("float64"); T = s.transform; crs = s.crs
    water = np.isnan(z); zf = np.where(water, np.nanmin(z), z)
    gy, gx = np.gradient(zf, 5.0)
    hs = np.clip(0.62 - 0.3 * gx / (np.hypot(gx, gy) + 0.25) + 0.3 * gy / (np.hypot(gx, gy) + 0.25), 0, 1)
    k = 2   # 10 m per basemap pixel
    hs = hs[::k, ::k]; wm = water[::k, ::k]
    rgb = np.zeros(hs.shape + (3,), dtype=np.uint8)
    land = (np.array([28, 40, 52]) + hs[..., None] * np.array([70, 80, 92])).astype(np.uint8)
    rgb[:] = land; rgb[wm] = (10, 16, 22)
    (ROOT / "demo/img").mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgb).save(ROOT / "demo/img/sf_basemap.png", optimize=True)
    Image.fromarray(rgb).save(ROOT / "assets/maps/sf_basemap.png", optimize=True)
    H, W = hs.shape
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True); inv = ~T
    def px(lon, lat):
        x, y = tr.transform(lon, lat); c, r = inv * (x, y); return round(c / k, 1), round(r / k, 1)
    C = D / "citywide"
    rows = list(csv.DictReader(open(C / "drain_rank.csv", encoding="utf-8")))
    drains = []
    for r in rows:
        x, y = px(float(r["lon"]), float(r["lat"]))
        drains.append([x, y, int(r["rank"]), round(float(r["score"]), 2), round(float(r["sump_m"]), 2),
                       int(float(r["captured_m2"])), int(r["flood311_75m"]), r["asset_id"]])
    hot = []
    for f in json.load(open(C / "hotspots.geojson"))["features"][:50]:
        p = f["properties"]; x, y = px(*f["geometry"]["coordinates"])
        hot.append([x, y, p["rank"], int(p["area_m2"]), round(p["max_depth_m"], 2), int(p["volume_m3"]),
                    p["flood311_150m"], bool(p["in_sfpuc_100yr"]), f["geometry"]["coordinates"]])
    f311 = []
    for r in csv.DictReader(open(C / "sf311_flooding.csv", encoding="utf-8")):
        x, y = px(float(r["lon"]), float(r["lat"]))
        f311.append([x, y])
    return {"basemap": "img/sf_basemap.png", "w": W, "h": H, "m_per_px": 5 * k,
            "drains": drains, "hotspots": hot, "flood311": f311, "summary": rj(C / "summary.json")}


def copy_only():
    """Low-memory path: reuse the committed demo/story-data.json; just copy images + lidar into demo/."""
    import shutil, base64
    for k, _ in HOTSPOT_SCENES + [("coast_scene", ""), ("coast_scene_lite", "")]:
        (ROOT / "demo/lidar").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / f"data/lidar/{k}.bin", ROOT / f"demo/lidar/{k}.bin")
    shutil.copytree(ROOT / "assets/nye311", ROOT / "demo/img/nye311", dirs_exist_ok=True)
    for a in ["charts/replay_rain.png", "charts/kelvin_gauge.png", "maps/rain_ground_truth.png", "maps/drain_priority.png",
              "lidar/rain_xsec.png", "lidar/coast_scene.png", "brand/logo.svg", "maps/sf_basemap.png"]:
        shutil.copyfile(ROOT / "assets" / a, ROOT / "demo/img" / pathlib_name(a))
    print("copied assets into demo/ (story-data.json unchanged)")


def pathlib_name(a):
    return a.split("/")[-1]


def main():
    import sys
    if "--copy-only" in sys.argv:
        return copy_only()
    k = rj(D / "kelvin_gauge_series.json")
    c = rj(D / "coastal_stack.json")
    t = rj(D / "christmas_tide.json")
    s = t["series"]
    if s and not isinstance(s[0], list):          # PowerShell flattened [t, v, t, v, ...]
        s = [[s[i], s[i + 1]] for i in range(0, len(s), 2)]
        t["series"] = s
        (D / "christmas_tide.json").write_text(json.dumps(t), encoding="utf-8")
    lid = rj(D / "lidar_checks.json")
    drains = rj(D / "drain_priority.geojson")["features"]
    nye = rj(ROOT / "data" / "ground_truth" / "sf311_rain_replay.geojson")["features"]
    bbox = (-122.4220, 37.7580, -122.4080, 37.7690)
    top = [{"rank": f["properties"]["rank"], "asset": f["properties"]["asset_id"],
            "lon": f["geometry"]["coordinates"][0], "lat": f["geometry"]["coordinates"][1],
            "area_m2": f["properties"]["captured_area_m2"], "nye311": f["properties"]["nye2022_311_within_60m"]}
           for f in drains[:12]]
    out = {
        "generated_from": "data/derived/*, data/ground_truth/* (see data/DATA_SOURCES.md)",
        "kelvin": {"y2026": k["daily_residual_2026"], "y2025": k["daily_residual_2025"],
                   "peak": {"t": k["oct2026_peak"]["t"], "v": float(k["oct2026_peak"]["v"])},
                   "thresholds": k["thresholds_ft_mllw"]},
        "coastal": c,
        "tide": {"series": s, "tz": t.get("tz")},
        "lidar": {"coast_bin": "lidar/coast_scene.bin", "coast_meta": rj(ROOT / "data" / "lidar" / "coast_scene.json"),
                  "checks": lid},
        "drains": {"bbox": bbox, "count": len(drains), "top": top,
                   "others": [[round(f["geometry"]["coordinates"][0], 6), round(f["geometry"]["coordinates"][1], 6)]
                              for f in drains[12:]],
                   "nye311": [[round(x, 6) for x in f["geometry"]["coordinates"]] for f in nye],
                   "site": [-122.4150, 37.7634]},
    }
    out["photos"] = []
    import re
    for m in rj(ROOT / "assets" / "nye311" / "photos.json"):
        place = re.sub(r"(\d)(Th|St|Nd|Rd)\b", lambda k: k.group(1) + k.group(2).lower(), m["place"]).replace(" And ", " & ")
        out["photos"].append({"id": m["id"], "time": m["time"], "place": place, "kind": m["kind"],
                              "lon": m["lon"], "lat": m["lat"], "src": "img/" + m["web"]})
    out["kelvin_outlook"] = rj(D / "kelvin_outlook.json")["events"]
    out["citywide"] = citywide()
    out["hotspot_scenes"] = [{"id": k, "title": t, "bin": f"lidar/{k}.bin"} for k, t in HOTSPOT_SCENES]
    import shutil
    for k, _ in HOTSPOT_SCENES:
        (ROOT / "demo/lidar").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / f"data/lidar/{k}.bin", ROOT / f"demo/lidar/{k}.bin")
    shutil.copytree(ROOT / "assets/nye311", ROOT / "demo/img/nye311", dirs_exist_ok=True)
    shutil.copyfile(ROOT / "data/lidar/coast_scene_lite.bin", ROOT / "demo/lidar/coast_scene_lite.bin")
    copies = {"data/lidar/coast_scene.bin": "demo/lidar/coast_scene.bin",
              "assets/charts/replay_rain.png": "demo/img/replay_rain.png",
              "assets/charts/kelvin_gauge.png": "demo/img/kelvin_gauge.png",
              "assets/maps/rain_ground_truth.png": "demo/img/rain_ground_truth.png",
              "assets/maps/drain_priority.png": "demo/img/drain_priority.png",
              "assets/lidar/rain_xsec.png": "demo/img/rain_xsec.png",
              "assets/lidar/coast_scene.png": "demo/img/coast_scene.png",
              "assets/brand/logo.svg": "demo/img/logo.svg"}
    for src, dst in copies.items():
        (ROOT / dst).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / src, ROOT / dst)
    import base64   # artifact hosts don't serve raw .bin; ship a base64 twin the page falls back to
    for b in (ROOT / "demo/lidar").glob("*.bin"):
        b.with_suffix(".b64.txt").write_text(base64.b64encode(b.read_bytes()).decode())
    p = ROOT / "demo" / "story-data.json"
    p.parent.mkdir(exist_ok=True)
    p.write_text(json.dumps(out, separators=(",", ":")), encoding="utf-8")
    print(f"wrote {p.relative_to(ROOT)} ({p.stat().st_size/1024:.0f} KB)")


if __name__ == "__main__":
    main()
