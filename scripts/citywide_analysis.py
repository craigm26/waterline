#!/usr/bin/env python3
"""Citywide screening for the city-manager views (no network; runs anywhere with the repo).

Inputs : data/terrain/sf_dem_5m.tif, data/derived/citywide/{drains.csv, sf311_flooding.csv, sfpuc_100yr_zone.geojson}
Outputs: data/derived/citywide/drain_rank.csv        all inlets: water reaching each grate (captured area), 311 history
         data/derived/citywide/top500_drains.geojson  the 500 that matter most
         data/derived/citywide/hotspots.geojson       ponding bowls (lidar depressions) ranked, with 311 + SFPUC overlap
         data/derived/citywide/summary.json           headline numbers
         assets/maps/citywide_drains.png, assets/maps/citywide_hotspots.png

Method (screening): 5 m bare-earth lidar DEM; open water/no-data set as outlet; priority-flood fill;
D8 directions; each inlet (snapped within 10 m to the highest-flow cell) intercepts what reaches it.
Ponding bowls = connected cells where fill depth >= 0.15 m and area >= 250 m².
Ignores pipes, curbs, buildings and pipe capacity.
"""
import csv
import heapq
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
C = ROOT / "data" / "derived" / "citywide"


def priority_flood(z):
    h, w = z.shape
    filled = z.copy()
    done = np.zeros(z.shape, dtype=bool)
    pq = []
    edge = np.zeros(z.shape, dtype=bool)
    edge[0, :] = edge[-1, :] = edge[:, 0] = edge[:, -1] = True
    for r, c in zip(*np.nonzero(edge)):
        pq.append((filled[r, c], int(r), int(c))); done[r, c] = True
    heapq.heapify(pq)
    nb = ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1))
    eps = 1e-5
    while pq:
        e, r, c = heapq.heappop(pq)
        for dr, dc in nb:
            rr, cc = r + dr, c + dc
            if 0 <= rr < h and 0 <= cc < w and not done[rr, cc]:
                done[rr, cc] = True
                v = filled[rr, cc]
                if v <= e:
                    v = e + eps; filled[rr, cc] = v
                heapq.heappush(pq, (v, rr, cc))
    return filled


def d8_targets(f):
    h, w = f.shape
    best = np.zeros((h, w)); tgt = np.full(h * w, -1, dtype=np.int64)
    pad = np.pad(f, 1, constant_values=np.inf)
    idx = np.arange(h * w).reshape(h, w)
    for dr, dc in ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)):
        nbz = pad[1 + dr:1 + dr + h, 1 + dc:1 + dc + w]
        s = (f - nbz) / (math.sqrt(2) if dr and dc else 1.0)
        m = s > best
        best = np.where(m, s, best)
        rr = np.clip(np.arange(h)[:, None] + dr, 0, h - 1); cc = np.clip(np.arange(w)[None, :] + dc, 0, w - 1)
        tgt = np.where(m.ravel(), (rr * w + cc).ravel(), tgt)
    return tgt


def main():
    import rasterio
    from pyproj import Transformer
    with rasterio.open(ROOT / "data/terrain/sf_dem_5m.tif") as s:
        z = s.read(1).astype("float64"); T = s.transform; crs = s.crs
    res = abs(T.a)
    water = np.isnan(z)
    z = np.where(water, -50.0, z)
    h, w = z.shape
    print(f"DEM {w}x{h} @ {res} m; priority flood ...")
    f = priority_flood(z)
    fill = np.where(water, 0, f - z)
    tgt = d8_targets(f)
    order = np.argsort(-f, axis=None)
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    inv = ~T
    # inlets
    inlets = []
    with open(C / "drains.csv", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            lo, la = float(row["lon"]), float(row["lat"])
            x, y = tr.transform(lo, la); c, r = inv * (x, y); r, c = int(r), int(c)
            if 2 <= r < h - 2 and 2 <= c < w - 2 and not water[r, c]:
                inlets.append({**row, "lon": lo, "lat": la, "r": r, "c": c})
    print(f"{len(inlets)} inlets on land")
    # plain accumulation for snapping
    acc = np.ones(h * w)
    for i in order:
        j = tgt[i]
        if j >= 0:
            acc[j] += acc[i]
    acc2 = acc.reshape(h, w)
    sink_of = {}
    for k, d in enumerate(inlets):
        win = acc2[d["r"] - 2:d["r"] + 3, d["c"] - 2:d["c"] + 3]
        a = int(np.argmax(win)); cell = (d["r"] - 2 + a // 5) * w + (d["c"] - 2 + a % 5)
        d["cell"] = cell; sink_of.setdefault(cell, []).append(k)
    sinks = np.zeros(h * w, dtype=bool); sinks[list(sink_of)] = True
    acc = np.ones(h * w); cap = np.zeros(h * w)
    for i in order:
        if sinks[i]:
            cap[i] += acc[i]; continue
        j = tgt[i]
        if j >= 0:
            acc[j] += acc[i]
    for cell, ks in sink_of.items():
        for k in ks:
            inlets[k]["captured_m2"] = cap[cell] * res * res / len(ks)
    # 311 history near each inlet (75 m)
    pts = []
    with open(C / "sf311_flooding.csv", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            pts.append((float(row["lon"]), float(row["lat"]), row["time"][:4]))
    P = np.array([[p[0], p[1]] for p in pts])
    kx = 88100.0; ky = 111000.0
    from collections import defaultdict
    grid = defaultdict(list)
    for i, (lo, la) in enumerate(P):
        grid[(int(lo * kx // 75), int(la * ky // 75))].append(i)
    for d in inlets:
        gx, gy = int(d["lon"] * kx // 75), int(d["lat"] * ky // 75)
        n = 0
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in grid.get((gx + dx, gy + dy), []):
                    if math.hypot((P[i, 0] - d["lon"]) * kx, (P[i, 1] - d["lat"]) * ky) <= 75:
                        n += 1
        d["flood311_75m"] = n
    from scipy import ndimage as _nd
    sump = _nd.maximum_filter(fill, size=2 * int(round(15 / res)) + 1)
    for d in inlets:
        sd = float(sump[d["r"], d["c"]]); d["sump_m"] = sd
        d["score"] = min(sd, 1.5) * math.log1p(d["captured_m2"])   # low spot x water reaching it (cap pits)
    inlets.sort(key=lambda d: -d["score"])
    for i, d in enumerate(inlets):
        d["rank"] = i + 1
    with open(C / "drain_rank.csv", "w", newline="", encoding="utf-8") as fh:
        wr = csv.writer(fh)
        wr.writerow(["rank", "asset_id", "lon", "lat", "score", "sump_m", "captured_m2", "flood311_75m", "neighborhood", "drain_type"])
        for d in inlets:
            wr.writerow([d["rank"], d["asset_id"], d["lon"], d["lat"], round(d["score"], 4), round(d["sump_m"], 3), round(d["captured_m2"]), d["flood311_75m"],
                         d["neighborhood"], d["drain_type"]])
    top = inlets[:500]
    json.dump({"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [d["lon"], d["lat"]]},
         "properties": {"rank": d["rank"], "asset_id": d["asset_id"], "captured_m2": round(d["captured_m2"]), "sump_m": round(d["sump_m"], 3),
                        "check": "deep >2 m: likely underpass/stairwell; verify" if d["sump_m"] > 2 else "",
                        "flood311_75m": d["flood311_75m"], "neighborhood": d["neighborhood"],
                        "provenance": "derived"}} for d in top]}, open(C / "top500_drains.geojson", "w"))
    # ponding bowls
    from scipy import ndimage
    bowl = (fill >= 0.15) & ~water
    lab, nlab = ndimage.label(bowl)
    areas = ndimage.sum(np.ones_like(fill), lab, index=np.arange(1, nlab + 1)) * res * res
    maxd = ndimage.maximum(fill, lab, index=np.arange(1, nlab + 1))
    vol = ndimage.sum(fill, lab, index=np.arange(1, nlab + 1)) * res * res
    com = ndimage.center_of_mass(bowl, lab, index=np.arange(1, nlab + 1))
    inv_tr = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)
    from shapely.geometry import shape, Point
    zone = shape(json.load(open(C / "sfpuc_100yr_zone.geojson"))["features"][0]["geometry"]).buffer(0)
    hs = []
    dgrid = defaultdict(list)   # city drains, for "is this low spot on the street network?"
    for d in inlets:
        dgrid[(int(d["lon"] * kx // 40), int(d["lat"] * ky // 40))].append((d["lon"], d["lat"]))
    for i in np.nonzero((areas >= 250) & (maxd <= 2.5))[0]:   # >2.5 m deep = lakes, quarries, stairwells
        r, c = com[i]; x, y = T * (c + 0.5, r + 0.5); lo, la = inv_tr.transform(x, y)
        gx, gy = int(lo * kx // 75), int(la * ky // 75)
        n = sum(1 for dx in (-2, -1, 0, 1, 2) for dy in (-2, -1, 0, 1, 2) for j in grid.get((gx + dx, gy + dy), [])
                if math.hypot((P[j, 0] - lo) * kx, (P[j, 1] - la) * ky) <= 150)
        ex, ey = int(lo * kx // 40), int(la * ky // 40)
        if not any(math.hypot((a - lo) * kx, (b - la) * ky) <= 40 for dx in (-1, 0, 1) for dy in (-1, 0, 1)
                   for a, b in dgrid.get((ex + dx, ey + dy), [])):
            continue   # not on the street network (park ponds, fields)
        hs.append({"lon": lo, "lat": la, "area_m2": float(areas[i]), "max_depth_m": float(maxd[i]),
                   "volume_m3": float(vol[i]), "flood311_150m": n, "in_sfpuc_100yr": bool(zone.contains(Point(lo, la)))})
    for x in hs:
        x["score"] = math.log10(1 + x["volume_m3"]) + 0.6 * math.log10(1 + x["flood311_150m"]) + (0.5 if x["in_sfpuc_100yr"] else 0)
    hs.sort(key=lambda x: -x["score"])
    for i, x in enumerate(hs):
        x["rank"] = i + 1
    json.dump({"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [round(x["lon"], 6), round(x["lat"], 6)]},
         "properties": {k: (round(v, 3) if isinstance(v, float) else v) for k, v in x.items() if k not in ("lon", "lat")}
         | {"provenance": "derived"}} for x in hs[:200]]}, open(C / "hotspots.geojson", "w"))
    # validation: do 311 flooding reports sit near top-ranked drains / in bowls more than chance?
    top_cells = set(d["cell"] for d in inlets[:500])
    rnd = np.random.default_rng(1)
    rand = [float(np.mean([inlets[i]["flood311_75m"] for i in rnd.choice(len(inlets), 500, replace=False)])) for _ in range(200)]
    by_area = sorted(inlets, key=lambda d: -d["captured_m2"])[:500]
    summ = {"inlets_ranked": len(inlets), "score": "min(sump depth within 15 m, 1.5 m) x log(1 + captured area)",
            "random500_mean_311_75m_p50_p95": [round(float(np.percentile(rand, 50)), 2), round(float(np.percentile(rand, 95)), 2)],
            "captured_area_only_top500_mean_311_75m": round(float(np.mean([d["flood311_75m"] for d in by_area])), 2), "top500_share_of_captured_area": round(sum(d["captured_m2"] for d in top) / sum(d["captured_m2"] for d in inlets), 3),
            "top500_mean_311_75m": round(float(np.mean([d["flood311_75m"] for d in top])), 2),
            "all_mean_311_75m": round(float(np.mean([d["flood311_75m"] for d in inlets])), 2),
            "street_bowls_ge_250m2": len(hs), "top50_hotspots_in_sfpuc_zone": sum(x["in_sfpuc_100yr"] for x in hs[:50]),
            "flood311_reports": len(P), "resolution_m": res,
            "method": "5 m lidar bare earth, priority-flood + D8, inlets intercept flow; bowls = fill depth >= 0.15 m"}
    json.dump(summ, open(C / "summary.json", "w"), indent=1)
    print(json.dumps(summ, indent=1))
    # maps
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    ext = [T.c, T.c + T.a * w, T.f + T.e * h, T.f]
    gy_, gx_ = np.gradient(np.where(water, np.nan, z), res)
    hsd = np.clip(0.75 - 0.35 * gx_ / (np.hypot(gx_, gy_) + 0.3) + 0.35 * gy_ / (np.hypot(gx_, gy_) + 0.3), 0, 1)
    for name, title in (("drains", "The 500 drains that matter most before Christmas"), ("hotspots", "Where water collects first: San Francisco")):
        fig, ax = plt.subplots(figsize=(16, 9), dpi=120, facecolor="#0a1016")
        fig.subplots_adjust(left=0.01, right=0.70, top=0.88, bottom=0.02)
        ax.set_facecolor("#0a1016")
        ax.imshow(np.where(water, np.nan, hsd), cmap="gray", extent=ext, vmin=-0.2, vmax=1.4, alpha=0.9)
        if name == "drains":
            xs = []; ys = []
            for d in inlets[500:]:
                x, y = tr.transform(d["lon"], d["lat"]); xs.append(x); ys.append(y)
            ax.scatter(xs, ys, s=0.6, color="#4c6378")
            xs = []; ys = []; ss = []
            for d in top:
                x, y = tr.transform(d["lon"], d["lat"]); xs.append(x); ys.append(y); ss.append(6 + 60 * (d["captured_m2"] / top[0]["captured_m2"]))
            ax.scatter(xs, ys, s=ss, color="#f2b33d", edgecolor="#0a1016", lw=0.4, zorder=5)
            note = (f"{len(inlets):,} city drains ranked by\nhow deep a low spot each grate sits in\nx the water reaching it.\n\n"
                    f"Top 500: {summ['top500_mean_311_75m']} past 311 flooding\nreports within 75 m on average.\nRandom 500: {summ['random500_mean_311_75m_p50_p95'][0]}.")
        else:
            ax.imshow(np.where(fill >= 0.15, np.minimum(fill, 2.0), np.nan), cmap="Blues", extent=ext, vmin=0, vmax=1.5, alpha=0.95)
            for x in hs[:50]:
                px, py = tr.transform(x["lon"], x["lat"])
                ax.scatter(px, py, s=90, facecolor="none", edgecolor="#f2b33d", lw=1.6, zorder=6)
            note = (f"Blue: low spots where water pools\non the lidar terrain.\nAmber rings: the top 50 street low spots\n"
                    f"by volume, past 311 flooding and the\ncity's 100-year zone ({summ['top50_hotspots_in_sfpuc_zone']} of 50 inside it).")
        ax.set_xticks([]); ax.set_yticks([])
        for sp in ax.spines.values():
            sp.set_visible(False)
        fig.text(0.02, 0.93, title, color="#e8eef3", fontsize=24, weight="bold")
        fig.text(0.72, 0.62, note, color="#e8eef3", fontsize=14, va="top")
        fig.text(0.72, 0.25, "USGS 3DEP lidar (5 m), SFPUC drains (DataSF jtgq-b7c5),\nSF 311 flooding reports, SFPUC 100-yr zone.\nScreening only: ignores pipes, curbs, buildings.",
                 color="#8fa3b5", fontsize=11, va="top")
        fig.savefig(ROOT / "assets" / "maps" / f"citywide_{name}.png", facecolor="#0a1016")
        plt.close(fig)
    print("maps written")


if __name__ == "__main__":
    main()
