#!/usr/bin/env python3
"""Rank real SF storm-drain inlets near 17th & Folsom by how much terrain drains to them.

Pre-event ANALYSIS asset (screening): bare-earth lidar DEM -> priority-flood fill -> D8 flow
directions -> upstream contributing area. Each SFPUC inlet (DataSF jtgq-b7c5, the Adopt-a-Drain
dataset) is snapped to the highest-accumulation cell within 6 m. Rank = contributing area.

Outputs
  data/derived/drain_priority.geojson     all inlets in the bbox with contributing area + rank
  data/derived/drain_walk.csv / .md       top-N walk list (nearest-neighbour order) with map links
  assets/maps/drain_priority.png          map: flow paths, ranked inlets, NYE-2022 311 flooding

Usage:  .venv\\Scripts\\python scripts\\drain_priority.py [--top 12]
Limits: bare earth ignores buildings, curbs below 1-2 m resolution and pipe capacity. It says
"where water converges", not "which drain will fail".
"""
from __future__ import annotations

import argparse
import csv
import heapq
import json
import math
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SITE = (37.7634, -122.4150)
BBOX = (-122.4220, 37.7580, -122.4080, 37.7690)
RES = 2.0  # metres


def getj(url, params):
    with urllib.request.urlopen(urllib.request.Request(url + "?" + urllib.parse.urlencode(params),
                                                       headers={"User-Agent": "waterline/0.5"}), timeout=90) as r:
        return json.loads(r.read())


def load_dem():
    import rasterio
    with rasterio.open(ROOT / "data" / "terrain" / "rain_dem_1m.tif") as src:
        z = src.read(1).astype("float64")
        t, crs = src.transform, src.crs
    f = int(RES / abs(t.a))
    h, w = (z.shape[0] // f) * f, (z.shape[1] // f) * f
    z = np.nanmean(z[:h, :w].reshape(h // f, f, w // f, f), axis=(1, 3))
    z = np.where(np.isnan(z), np.nanmax(z), z)
    from rasterio.transform import Affine
    return z, Affine(t.a * f, t.b, t.c, t.d, t.e * f, t.f), crs


def priority_flood(z):
    """Barnes et al. priority-flood with epsilon so every cell drains to the edge."""
    h, w = z.shape
    filled = z.copy()
    done = np.zeros_like(z, dtype=bool)
    pq = []
    for r in range(h):
        for c in (0, w - 1):
            heapq.heappush(pq, (filled[r, c], r, c)); done[r, c] = True
    for c in range(1, w - 1):
        for r in (0, h - 1):
            heapq.heappush(pq, (filled[r, c], r, c)); done[r, c] = True
    eps = 1e-5
    nb = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    while pq:
        e, r, c = heapq.heappop(pq)
        for dr, dc in nb:
            rr, cc = r + dr, c + dc
            if 0 <= rr < h and 0 <= cc < w and not done[rr, cc]:
                done[rr, cc] = True
                if filled[rr, cc] <= e:
                    filled[rr, cc] = e + eps
                heapq.heappush(pq, (filled[rr, cc], rr, cc))
    return filled


def d8_accumulation(f):
    h, w = f.shape
    nb = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    best = np.zeros((h, w)); tgt = np.full((h, w), -1, dtype=np.int64)
    pad = np.pad(f, 1, constant_values=np.inf)
    for k, (dr, dc) in enumerate(nb):
        nbz = pad[1 + dr:1 + dr + h, 1 + dc:1 + dc + w]
        slope = (f - nbz) / (math.sqrt(2) if dr and dc else 1.0)
        better = slope > best
        best = np.where(better, slope, best)
        rr, cc = np.meshgrid(np.arange(h) + dr, np.arange(w) + dc, indexing="ij")
        tgt = np.where(better, rr * w + cc, tgt)
    acc = np.ones(h * w)
    order = np.argsort(-f, axis=None)
    tf = tgt.ravel()
    for i in order:
        j = tf[i]
        if j >= 0:
            acc[j] += acc[i]
    return acc.reshape(h, w) * RES * RES, order, tf   # m² contributing area


def captured_area(order, tf, sinks, shape):
    """Each inlet cell captures what reaches it and passes nothing downstream (inlet intercepts flow)."""
    acc = np.ones(shape[0] * shape[1])
    cap = {}
    for i in order:
        if i in sinks:
            cap[i] = cap.get(i, 0) + acc[i]
            continue
        j = tf[i]
        if j >= 0:
            acc[j] += acc[i]
    return {k: v * RES * RES for k, v in cap.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--map-only", action="store_true", help="re-render the map from the saved geojson (no network)")
    a = ap.parse_args()
    from pyproj import Transformer
    z, t, crs = load_dem()
    print(f"DEM {z.shape[1]}x{z.shape[0]} at {RES} m; filling + D8 ...")
    filled = priority_flood(z)
    acc, order, tf = d8_accumulation(filled)
    from scipy import ndimage
    sump = ndimage.maximum_filter(filled - z, size=2 * int(round(15 / RES)) + 1)   # deepest low spot within 15 m
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    nye = [f["geometry"]["coordinates"] for f in
           json.load(open(ROOT / "data" / "ground_truth" / "sf311_rain_replay.geojson"))["features"]]
    if a.map_only:   # re-rank + re-render from the saved inlets (no network)
        feats = json.load(open(ROOT / "data" / "derived" / "drain_priority.geojson"))["features"]
        return finish(a, z, t, tr, acc, sump, feats, nye)
    inlets = getj("https://data.sf.gov/resource/jtgq-b7c5.json",
                  {"$where": f"within_box(location,{BBOX[3]},{BBOX[0]},{BBOX[1]},{BBOX[2]})", "$limit": "5000"})
    print(f"{len(inlets)} inlets in bbox")
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    inv = ~t
    nye = [f["geometry"]["coordinates"] for f in
           json.load(open(ROOT / "data" / "ground_truth" / "sf311_rain_replay.geojson"))["features"]]
    feats = []
    snap = int(round(6 / RES))
    for d in inlets:
        lon, lat = d["location"]["coordinates"]
        x, y = tr.transform(lon, lat)
        c, r = inv * (x, y)
        r, c = int(r), int(c)
        if not (snap <= r < z.shape[0] - snap and snap <= c < z.shape[1] - snap):
            continue
        win = acc[r - snap:r + snap + 1, c - snap:c + snap + 1]
        k = int(np.argmax(win)); rr, cc = r - snap + k // win.shape[1], c - snap + k % win.shape[1]
        area = float(win.max())
        cell = rr * z.shape[1] + cc
        near311 = sum(1 for (lo, la) in nye if math.hypot((lo - lon) * 88000, (la - lat) * 111000) <= 60)
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
                      "properties": {"asset_id": d.get("puc_maximo_asset_id"), "drain_type": d.get("drain_type"),
                                     "system_use": d.get("system_use"), "contrib_area_m2": round(area),
                                     "nye2022_311_within_60m": near311,
                                     "_cell": cell, "provenance": "derived",
                                     "source": "SFPUC inlets jtgq-b7c5 (official) + USGS 3DEP 1 m D8 contributing area (derived)"}})
    cap = captured_area(order, tf, {f["properties"]["_cell"] for f in feats}, z.shape)
    shared = {}
    for f in feats:
        shared.setdefault(f["properties"]["_cell"], []).append(f)
    for cell, fs in shared.items():   # inlets snapped to the same cell split its catch
        for f in fs:
            f["properties"]["captured_area_m2"] = round(cap.get(cell, 0) / len(fs))
            f["properties"]["upstream_area_m2"] = f["properties"].pop("contrib_area_m2")
            f["properties"].pop("_cell")
    return finish(a, z, t, tr, acc, sump, feats, nye)


def finish(a, z, t, tr, acc, sump, feats, nye):
    # Score: drain sits in a low spot (sump depth within 15 m) x log(water reaching it).
    # Citywide check (scripts/citywide_analysis.py): this picks drains with ~1.7x the average past 311
    # flooding reports; captured area alone did no better than random.
    inv = ~t
    for f in feats:
        x, y = tr.transform(*f["geometry"]["coordinates"]); c, r = inv * (x, y)
        s = float(sump[int(r), int(c)]); p = f["properties"]
        p["sump_depth_m"] = round(s, 3)
        p["check"] = "deep >2 m: likely underpass/stairwell/excavation; verify" if s > 2 else ""
        p["score"] = round(min(s, 1.5) * math.log1p(p["captured_area_m2"]), 4)   # cap: bare-earth pits aren't street sumps
    feats.sort(key=lambda f: -f["properties"]["score"])
    for i, f in enumerate(feats):
        f["properties"]["rank"] = i + 1
    out = ROOT / "data" / "derived" / "drain_priority.geojson"
    json.dump({"type": "FeatureCollection", "features": feats}, open(out, "w"), indent=1)

    # walk order: nearest neighbour from the corner
    top = feats[:a.top]
    pos, rem, walk = SITE[::-1], top[:], []
    while rem:
        nxt = min(rem, key=lambda f: math.hypot((f["geometry"]["coordinates"][0] - pos[0]) * 88000,
                                                (f["geometry"]["coordinates"][1] - pos[1]) * 111000))
        walk.append(nxt); rem.remove(nxt); pos = nxt["geometry"]["coordinates"]
    rows = []
    for k, f in enumerate(walk, 1):
        lon, lat = f["geometry"]["coordinates"]; p = f["properties"]
        rows.append({"stop": k, "rank": p["rank"], "asset_id": p["asset_id"], "lat": round(lat, 6), "lon": round(lon, 6),
                     "sump_depth_m": p["sump_depth_m"], "captured_area_m2": p["captured_area_m2"], "nye2022_311_within_60m": p["nye2022_311_within_60m"],
                     "map": f"https://www.google.com/maps/search/?api=1&query={lat:.6f},{lon:.6f}"})
    with open(ROOT / "data" / "derived" / "drain_walk.csv", "w", newline="", encoding="utf-8") as fh:
        wr = csv.DictWriter(fh, fieldnames=list(rows[0])); wr.writeheader(); wr.writerows(rows)
    md = ["# Drain walk: photograph each grate (top, straight down, plus one wide shot)", "",
          "Ranked by how deep a low spot each grate sits in (lidar, within 15 m) times the water reaching it.",
          "Citywide, this score picks drains with ~1.7x the average past 311 flooding. Walk order starts at 17th & Folsom.", "",
          "| Stop | Rank | Asset | Low-spot depth | Drains to it | 311 NYE-22 within 60 m | Map |", "|---|---|---|---|---|---|---|"]
    md += [f"| {r['stop']} | {r['rank']} | {r['asset_id']} | {r['sump_depth_m']*100:.0f} cm | {r['captured_area_m2']:,} m² | {r['nye2022_311_within_60m']} | "
           f"[{r['lat']}, {r['lon']}]({r['map']}) |" for r in rows]
    (ROOT / "data" / "derived" / "drain_walk.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f"top {a.top}: " + ", ".join(f"#{f['properties']['rank']} {f['properties']['captured_area_m2']:,} m2" for f in top))

    render_map(z, t, tr, acc, feats, top, nye, a.top)
    return top


def render_map(z, t, tr, acc, feats, top, nye, ntop):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ext = [t.c, t.c + t.a * z.shape[1], t.f + t.e * z.shape[0], t.f]
    gy, gx = np.gradient(z, RES)
    hs = np.clip(0.7 * np.cos(np.arctan(np.hypot(gx, gy))) + 0.3 * (gx - gy) / (np.hypot(gx, gy) + 1e-6) * np.sin(np.arctan(np.hypot(gx, gy))), 0, 1)
    fig, ax = plt.subplots(figsize=(16, 9), dpi=120)
    fig.subplots_adjust(left=0.02, right=0.70, top=0.86, bottom=0.04)
    ax.imshow(hs, cmap="gray", extent=ext, vmin=0, vmax=1.3)
    la = np.log10(acc)
    ax.imshow(np.where(acc > 2000, la, np.nan), cmap="Blues", extent=ext, vmin=3, vmax=5.5, alpha=0.9)
    xs, ys, ss = [], [], []
    for f in feats:
        x, y = tr.transform(*f["geometry"]["coordinates"]); xs.append(x); ys.append(y)
    ax.scatter(xs, ys, s=10, color="#5f6b78", zorder=4, label="SFPUC storm-drain inlets")
    for (lo, la_) in nye:
        x, y = tr.transform(lo, la_)
        ax.scatter(x, y, s=60, color="#b3261e", marker="o", edgecolor="white", lw=1, zorder=5)
    for f in top:
        x, y = tr.transform(*f["geometry"]["coordinates"])
        ax.scatter(x, y, s=420, color="#d9a21b", edgecolor="#1f2933", lw=1.5, zorder=6)
        ax.text(x, y, str(f["properties"]["rank"]), ha="center", va="center", fontsize=11, weight="bold", zorder=7)
    sx, sy = tr.transform(SITE[1], SITE[0])
    ax.scatter(sx, sy, s=300, marker="+", color="#1f2933", lw=3, zorder=8)
    ax.set_xticks([]); ax.set_yticks([])
    for sp in ax.spines.values():
        sp.set_visible(False)
    fig.suptitle(f"The {ntop} drains that matter most around 17th & Folsom", x=0.02, ha="left", y=0.95,
                 fontsize=24, weight="bold", color="#1f2933")
    import matplotlib.lines as ml
    leg = [ml.Line2D([], [], marker="o", ls="", color="#d9a21b", mec="#1f2933", ms=14, label=f"top {ntop}: deepest low spot x water reaching it"),
           ml.Line2D([], [], marker="o", ls="", color="#5f6b78", ms=5, label=f"other inlets ({len(feats) - ntop})"),
           ml.Line2D([], [], marker="o", ls="", color="#b3261e", ms=8, label="311 flooding, Dec 31 2022"),
           ml.Line2D([], [], color="#2f80c1", lw=4, label="where surface water converges")]
    fig.legend(handles=leg, loc="center left", bbox_to_anchor=(0.71, 0.58), frameon=False, fontsize=14)
    fig.text(0.71, 0.32, "Inlets: SFPUC / DataSF jtgq-b7c5 (Adopt-a-Drain).\nScore: lidar low-spot depth within 15 m x\nwater reaching the grate (2 m, D8).\nScreening only: ignores pipes, curbs, buildings.",
             fontsize=12, color="#7b8794", va="top")
    fig.savefig(ROOT / "assets" / "maps" / "drain_priority.png")
    print("wrote drain_priority.geojson, drain_walk.csv/.md, assets/maps/drain_priority.png")


if __name__ == "__main__":
    main()
