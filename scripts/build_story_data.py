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
    desk = storm_desk(rows, hot, px)
    return {"basemap": "img/sf_basemap.png", "w": W, "h": H, "m_per_px": 5 * k,
            "drains": drains, "hotspots": hot, "flood311": f311, "summary": rj(C / "summary.json"), "storm_desk": desk}


def storm_desk(rows, hot, px):
    """Scripted 72-hour Storm Desk run built from real data (drains, hotspots, tide windows).
    The storm is a labelled scenario; every outbound action is a draft awaiting human approval."""
    import collections
    tide = rj(D / "christmas_tide.json")["series"]
    if tide and not isinstance(tide[0], list):
        tide = [[tide[i], tide[i + 1]] for i in range(0, len(tide), 2)]
    stack = rj(D / "coastal_stack.json"); base = stack["baseline_ft"]; th = stack["thresholds"]
    wins, cur = [], None
    for t, v in tide:
        on = float(v) + base >= th["nos_minor"]
        if on and not cur: cur = [t, t, float(v) + base]
        elif on: cur[1] = t; cur[2] = max(cur[2], float(v) + base)
        elif cur: wins.append(cur); cur = None
    if cur: wins.append(cur)
    hm = lambda t: t[11:16]
    street = [r for r in rows if int(r["rank"]) <= 500 and float(r["sump_m"]) <= 2.0]
    verify = [r for r in rows if int(r["rank"]) <= 500 and float(r["sump_m"]) > 2.0]
    zones = collections.Counter(r["neighborhood"] for r in street).most_common(8)
    hs_names = {1: "SoMa by Mission Creek", 2: "14th–15th & Folsom", 3: "Lower Great Highway", 4: "Islais Creek / Dogpatch", 7: "Bayview, 3rd St"}
    hs_pts = [[h[0], h[1], "hot"] for h in hot if h[2] in hs_names]
    def pts(rs, n=60): return [[*px(float(r["lon"]), float(r["lat"])), "drain"] for r in rs[:n]]
    fb = [*px(-122.3935, 37.7955), "coast"]
    folsom12 = rj(D / "drain_priority.geojson")["features"][:12]
    f12 = [[*px(*f["geometry"]["coordinates"]), "drain"] for f in folsom12]
    w = {x[0][:10]: x for x in wins}
    d23, d24, d25 = w.get("2026-12-23"), w.get("2026-12-24"), w.get("2026-12-25")
    E = []
    def ev(t, tag, title, body, argon, approval, targets=(), metrics=None):
        E.append({"t": t, "tag": tag, "title": title, "body": body, "argon": argon, "approval": approval,
                  "targets": list(targets), "metrics": metrics or {}})
    ev("2026-12-21T06:00", "detect", "Incident opened: king tides + El Niño + storm",
       f"The tide agent sees NOS-minor coastal flooding windows on Dec 23 ({hm(d23[0])}–{hm(d23[1])}), Dec 24 ({hm(d24[0])}–{hm(d24[1])}, peak {d24[2]:.1f} ft) and Dec 25. "
       f"The live gauge still runs +{base:.2f} ft above prediction. Scenario: the forecast agent's ensemble shows an atmospheric river arriving the night of Dec 23. "
       "The coordinator opens a Storm Desk incident and sets a 72-hour plan.",
       "Long-horizon autonomy: one goal, a 72-hour plan, no turn-by-turn prompting", "auto", [fb] + hs_pts, {"phase": "Watch"})
    ev("2026-12-21T06:07", "plan", f"{len(street)} street drains to clear before the storm",
       f"Re-ranks all 23,835 city drains for this storm. Of the top 500, {len(street)} sit in street low spots; {len(verify)} sit in pits deeper than 2 m (underpasses, stairwells) and go to a human to verify. "
       "Groups the street drains into crew zones: " + ", ".join(f"{n} ({c})" for n, c in zones[:6]) + ".",
       "Orchestrates Flash subagents: one per neighborhood, in parallel", "auto", pts(street, 120), {"drains": len(street)})
    ev("2026-12-21T06:15", "notify", "Drafted: notices to Adopt-a-Drain adopters",
       f"One message per adopted drain among the {len(street)}: which grate, why it matters (low spot, water reaching it), clear it before Dec 23 6 PM, don't clear it during the storm, report blockages to 311. Batched for the Rain Ready SF contact list.",
       "Writes 500 personalized messages from one plan", "required", pts(street, 120), {"drafts": len(street)})
    ev("2026-12-21T07:02", "approve", "Approved by the duty manager", "Notices go out through the city's own channel. Waterline never sends on its own.",
       "Human in the loop", "approved", [], {"approved": 1})
    ev("2026-12-22T09:30", "dispatch", "Scouting the 12 drains at 17th & Folsom",
       "Rover and volunteer photos of the 12 priority grates around 17th & Folsom come in. Gemini reads each photo: clear, partly blocked or blocked. Blocked grates become drafted Public Works work orders with the asset ID, photo and location.",
       "Multimodal: reads grate photos and decides", "required", f12, {"work_orders": "Sun"})
    ev("2026-12-22T14:00", "rerun", "Re-run: what clearing them buys",
       "The hydraulics agent re-runs the New Year's Eve 2022 replay with the blocked drains cleared and reports the drop in flooded area at 17th & Folsom.",
       "Writes and runs its own model, graded against reality", "sunday", f12, {"payoff": "Sun"})
    ev("2026-12-23T05:40", "replan", "Forecast shifted: storm 6 hours earlier",
       f"The new ensemble pulls the rain onto the Dec 23 morning high tide ({hm(d23[0])}–{hm(d23[1])}). The coordinator re-plans: sandbag pickup moves up, Embarcadero staging moves to the Dec 23 window, and adopters who haven't confirmed get a reminder.",
       "Re-plans when the world changes, and says why", "required", [fb] + hs_pts, {"phase": "Warning"})
    ev("2026-12-23T07:00", "stage", "Drafted: crew staging at the five worst low spots",
       "Barricades and pump-truck staging at " + ", ".join(hs_names[k] for k in (1, 2, 4, 7, 3)) + ", each with the lidar bowl map, the fill depth at which the street floods, and past 311 history attached. Port of SF crew request drafted for the Embarcadero seawall during the tide windows.",
       "Turns lidar into field instructions", "required", hs_pts + [fb], {"sites": 6})
    ev("2026-12-23T09:00", "alert", "Drafted: resident alerts in English, Spanish and Chinese",
       f"Street-level alerts for the hotspot zones and the Ferry Building waterfront: time window, expected depth band, three actions. Sent through AlertSF opt-in by a person, not by Waterline.",
       "Writes plain-language alerts, three languages", "required", hs_pts + [fb], {"alerts": 3})
    ev("2026-12-24T08:30", "monitor", "Live: 311 reports matched to predictions",
       "As 311 flooding reports and photos arrive, Gemini reads each photo, estimates depth and checks it against the predicted depth at that spot. Where reality runs deeper than the model, it flags the block and asks for a crew.",
       "Reads incoming photos and finds where the model is wrong", "auto", hs_pts, {"phase": "Event"})
    ev(d24[0].replace(" ", "T"), "peak", f"Peak: {d24[2]:.1f} ft MLLW at the gauge",
       "Coordinator posts the situation brief every 30 minutes: where water is, what's staged, what's open.", "Keeps the whole picture in one long context", "auto", [fb], {})
    ev("2026-12-24T15:00", "review", "After-action review",
       "Compares predicted against reported flooding street by street, writes what to change (thresholds, drains that failed, sites that surprised it) into the next run's playbook.",
       "Reflects on its own run and improves the next one", "auto", [], {"phase": "Recovery"})
    return {"scenario": "Scenario: Christmas-week king tides (NOAA) with an assumed atmospheric-river storm. Drains, low spots, tide windows and neighborhoods are real data. Every outbound action is a draft for human approval.",
            "events": E, "zones": zones, "street_drains": len(street), "verify_drains": len(verify)}


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
