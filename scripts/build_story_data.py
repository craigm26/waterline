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


def main():
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
    import shutil
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
    p = ROOT / "demo" / "story-data.json"
    p.parent.mkdir(exist_ok=True)
    p.write_text(json.dumps(out, separators=(",", ":")), encoding="utf-8")
    print(f"wrote {p.relative_to(ROOT)} ({p.stat().st_size/1024:.0f} KB)")


if __name__ == "__main__":
    main()
