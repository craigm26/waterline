#!/usr/bin/env python3
"""Build pre-event demo ASSETS (data products, charts, maps). Not app code.

Run after `python scripts/stage_data.py --download-dem`, inside the repo venv:
    .venv\\Scripts\\python scripts\\build_assets.py            (Windows)
    .venv/bin/python scripts/build_assets.py                    (macOS/Linux)
    ... --only charts forecast                                  (subset)

Needs: numpy rasterio shapely pyproj matplotlib pillow scipy

Outputs (committed; small):
  assets/charts/   kelvin_gauge, coastal_stack, replay_rain, ensemble_fan  (.png 1920x1080 + .svg)
  assets/maps/     rain_ground_truth.png, coast_elevation_bands.png
  data/terrain/    {site}_dem_1m.tif (clipped, LZW), {site}_heightmap16.png, {site}_hillshade.png,
                   {site}_terrain.json (bounds, CRS, min/max, georeferencing for Three.js)
  data/ground_truth/ sf311_{site}_replay.geojson, sfpuc_100yr_zone_{site}.geojson, dry_controls_rain.geojson
  data/forecast/   ensemble_{site}_{model}_{date}.json  (Open-Meteo GFS/ECMWF ensembles; fallback source)
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import statistics as stats
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
A = ROOT / "assets"
UA = {"User-Agent": "waterline-hackathon-prep/0.3"}
STATION = "9414290"
SITES = {
    "rain": {"name": "17th & Folsom", "lat": 37.7634, "lon": -122.4150,
             "bbox": (-122.4220, 37.7580, -122.4080, 37.7690)},
    "coast": {"name": "Ferry Building / Embarcadero", "lat": 37.7955, "lon": -122.3935,
              "bbox": (-122.3990, 37.7905, -122.3880, 37.8000)},
}
NAVD88_TO_MLLW_FT = 0.06   # NAVD88 zero = -0.06 ft MLLW at 9414290 (stage_data tide_datums)
M_TO_FT = 3.28084

# --- palette: muted, colorblind-safe; provenance encoded by fill style, not hue ---
INK, MUTED, GRID = "#1f2933", "#7b8794", "#e4e7eb"
WATER, WATER_DARK, ALERT, ALERT2, ALERT3 = "#2f80c1", "#1b4f7a", "#d9a21b", "#d66a1f", "#b3261e"


def get(url, params=None, timeout=90):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read()


def getj(url, params=None):
    return json.loads(get(url, params))


def out(p: Path) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def rawj(name):
    return json.loads((RAW / name).read_text())


# ----------------------------------------------------------------- plotting setup
def plt_setup():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 15, "axes.edgecolor": MUTED,
        "axes.labelcolor": INK, "xtick.color": MUTED, "ytick.color": MUTED,
        "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
        "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True,
        "figure.facecolor": "white", "savefig.facecolor": "white",
    })
    return plt


def save_fig(fig, stem):
    for ext in ("png", "svg"):
        fig.savefig(out(A / "charts" / f"{stem}.{ext}"), dpi=120 if ext == "png" else None)
    print(f"  chart {stem}")


def source_note(ax, text):
    ax.annotate(text, xy=(0, -0.13), xycoords="axes fraction", fontsize=11, color=MUTED, ha="left")


# ----------------------------------------------------------------- CO-OPS helpers
def coops(product, b, e, **extra):
    p = {"product": product, "station": STATION, "begin_date": b, "end_date": e, "datum": "MLLW",
         "units": "english", "time_zone": "gmt", "format": "json", "application": "waterline", **extra}
    d = getj("https://api.tidesandcurrents.noaa.gov/api/prod/datagetter", p)
    return d.get("data") or d.get("predictions") or []


def daily_residual(b, e, product):
    obs = coops(product, b, e)
    pred = coops("predictions", b, e, **({"interval": "h"} if product == "hourly_height" else {}))
    pm = {x["t"]: float(x["v"]) for x in pred}
    days: dict[str, list[float]] = {}
    for x in obs:
        if x.get("v") and x["t"] in pm:
            days.setdefault(x["t"][:10], []).append(float(x["v"]) - pm[x["t"]])
    return {d: stats.mean(v) for d, v in sorted(days.items())}


# ----------------------------------------------------------------- charts
def chart_kelvin():
    plt = plt_setup()
    import matplotlib.dates as mdates
    today = dt.date.today()
    cur = {**daily_residual("20260901", "20260930", "hourly_height"),
           **daily_residual("20261001", today.strftime("%Y%m%d"), "water_level")}
    prev = {**daily_residual("20250901", "20250930", "hourly_height"),
            **daily_residual("20251001", "20251031", "hourly_height")}
    fl = rawj("flood_levels_mllw.json")["ft_mllw"]
    octobs = coops("water_level", "20261001", today.strftime("%Y%m%d"))
    peak = max((x for x in octobs if x.get("v")), key=lambda x: float(x["v"]))
    json.dump({"daily_residual_2026": cur, "daily_residual_2025": prev, "oct2026_peak": peak,
               "thresholds_ft_mllw": fl},
              open(out(ROOT / "data" / "derived" / "kelvin_gauge_series.json"), "w"), indent=1)

    fig, (a1, a2) = plt.subplots(1, 2, figsize=(16, 9), gridspec_kw={"width_ratios": [1.35, 1]})
    fig.subplots_adjust(left=0.07, right=0.97, top=0.80, bottom=0.17, wspace=0.28)
    to_dt = lambda k: dt.datetime.strptime(k, "%Y-%m-%d")
    xs = [to_dt(k) for k in cur]
    xp = [to_dt(k).replace(year=2026) for k in prev]
    a1.plot(xp, list(prev.values()), color=MUTED, lw=2, label="2025")
    a1.plot(xs, list(cur.values()), color=WATER, lw=3.2, label="2026")
    a1.axhline(0, color=INK, lw=1)
    a1.set_ylabel("Observed minus predicted (ft)")
    a1.set_title("Daily mean water level above prediction", loc="left", fontsize=16, color=INK)
    a1.text(xs[-1], list(cur.values())[-1], "  2026", color=WATER, va="center", fontsize=14, weight="bold")
    a1.text(xp[-1], list(prev.values())[-1], "  2025", color=MUTED, va="center", fontsize=14)
    a1.xaxis.set_major_formatter(mdates.DateFormatter("%b %d"))
    a1.xaxis.set_major_locator(mdates.WeekdayLocator(interval=2))
    source_note(a1, "NOAA CO-OPS 9414290 San Francisco. Sep: verified hourly; Oct: preliminary 6-min.")

    tt = [dt.datetime.strptime(x["t"], "%Y-%m-%d %H:%M") - dt.timedelta(hours=7) for x in octobs if x.get("v")]
    vv = [float(x["v"]) for x in octobs if x.get("v")]
    a2.plot(tt, vv, color=WATER_DARK, lw=0.9)
    a2.axhline(fl["nws_minor"], color=ALERT, lw=2, ls="--")
    a2.text(tt[0], fl["nws_minor"] + 0.08, f"NWS minor flood  {fl['nws_minor']:.2f} ft", color=ALERT, fontsize=13)
    pt = dt.datetime.strptime(peak["t"], "%Y-%m-%d %H:%M") - dt.timedelta(hours=7)
    a2.scatter([pt], [float(peak["v"])], color=ALERT3, zorder=5, s=60)
    a2.annotate(f"{pt:%b %d}: {float(peak['v']):.2f} ft", (pt, float(peak["v"])), xytext=(10, 8),
                textcoords="offset points", color=ALERT3, fontsize=13, weight="bold")
    a2.set_ylabel("Water level (ft MLLW)")
    a2.set_title("October 2026, every 6 minutes", loc="left", fontsize=16, color=INK)
    a2.xaxis.set_major_formatter(mdates.DateFormatter("%b %d"))
    a2.xaxis.set_major_locator(mdates.DayLocator(interval=7))
    m26 = stats.mean([v for k, v in cur.items() if k.startswith("2026-10")])
    m25 = stats.mean([v for k, v in prev.items() if k.startswith("2025-10")])
    fig.suptitle("San Francisco is running high: the El Niño Kelvin wave is already here",
                 x=0.07, ha="left", y=0.95, fontsize=24, weight="bold", color=INK)
    fig.text(0.07, 0.86, f"October mean: {m26:+.2f} ft above prediction in 2026 vs {m25:+.2f} ft in 2025 "
             f"(about {12 * (m26 - m25):.0f} inches of extra sea level)", fontsize=16, color=INK)
    save_fig(fig, "kelvin_gauge")


def chart_coastal_stack():
    plt = plt_setup()
    fl = rawj("flood_levels_mllw.json")["ft_mllw"]
    ka = rawj("kelvin_anomaly.json")
    highs = rawj(f"tide_predictions_hilo_{STATION}.json")
    spots = rawj("spot_elevations_navd88_ft.json")
    king = highs[0]
    tide = float(king["v"])
    base = ka["Oct 2026 to date"][0]
    storm_typ = 2.0
    stress = ka["Feb 1998"][1]
    plaza = spots["Ferry Bldg front plaza"] + NAVD88_TO_MLLW_FT
    scen = [("King tide\nalone", tide, "official"),
            ("+ El Niño baseline\n(today's gauge)", tide + base, "official"),
            ("+ big storm\n(+2.0 ft surge)", tide + storm_typ, "assumed"),
            ("Stress test\n(Feb 1998 peak)", tide + stress, "assumed")]
    json.dump({"king_tide": king, "baseline_ft": base, "storm_typ_ft": storm_typ, "stress_ft": stress,
               "plaza_ft_mllw": plaza, "scenarios": [[s[0].replace("\n", " "), round(s[1], 2), s[2]] for s in scen],
               "thresholds": fl}, open(out(ROOT / "data" / "derived" / "coastal_stack.json"), "w"), indent=1)

    fig, ax = plt.subplots(figsize=(16, 9))
    fig.subplots_adjust(left=0.07, right=0.80, top=0.80, bottom=0.17)
    x = np.arange(len(scen))
    for i, (lab, v, prov) in enumerate(scen):
        hatch = "///" if prov == "assumed" else None
        ax.bar(i, v, width=0.62, color=WATER if prov == "official" else "white",
               edgecolor=WATER_DARK, hatch=hatch, lw=1.6)
        ax.text(i, v + 0.12, f"{v:.1f} ft", ha="center", fontsize=17, weight="bold", color=INK)
    for k, lab, c in [("nws_minor", "NWS minor", ALERT), ("nos_minor", "NOS minor", ALERT),
                      ("nos_moderate", "NOS moderate", ALERT2), ("nos_major", "NOS major", ALERT3)]:
        ax.axhline(fl[k], color=c, lw=1.4, ls="--")
        ax.text(len(scen) - 0.45, fl[k], f" {lab} {fl[k]:.2f}", color=c, va="center", fontsize=13)
    ax.axhspan(plaza, plaza + 0.25, color="#8d6e63", alpha=0.85)
    ax.text(len(scen) - 0.45, plaza + 0.12, f" Ferry Building plaza ≈ {plaza:.1f}", color="#5d4037",
            va="center", fontsize=13, weight="bold")
    ax.set_xticks(x, [s[0] for s in scen], fontsize=14)
    ax.set_ylim(5.5, max(plaza, scen[-1][1]) + 0.9)
    ax.set_xlim(-0.6, len(scen) - 0.45)
    ax.set_ylabel("Still water at the SF gauge (ft MLLW)")
    local = dt.datetime.strptime(king["t"], "%Y-%m-%d %H:%M")
    fig.suptitle(f"Christmas Eve king tide, stacked: {local:%b %d %H:%M}", x=0.07, ha="left", y=0.95,
                 fontsize=24, weight="bold", color=INK)
    fig.text(0.07, 0.86, "Solid = measured or predicted by NOAA.  Hatched = assumed scenario (surge size).  "
             "Waves on top of still water are not modeled.", fontsize=14, color=INK)
    source_note(ax, "NOAA CO-OPS 9414290 predictions, observed residuals and flood levels; USGS 3DEP 1 m ground "
                "elevation (NAVD88 ≈ MLLW + 0.06 ft). Stress test is not a forecast.")
    save_fig(fig, "coastal_stack")


def chart_replay_rain():
    plt = plt_setup()
    rows = (RAW / "rain_hourly_sfo_20221231.csv").read_text().strip().splitlines()[1:]
    t, v = [], []
    for r in rows:
        _, ts, x = r.split(",")
        t.append(dt.datetime.strptime(ts, "%Y-%m-%d %H:%M"))
        v.append(0.0 if x in ("M", "T") else float(x))
    daily = {d["DATE"]: float(d["PRCP"]) for d in rawj("rain_daily_sf_downtown.json")}
    scale = daily["2022-12-31"] / max(sum(v[:24]), 1e-6)
    vs = [x * scale for x in v]
    a14 = rawj("atlas14_pfds.json")["depth"]["24-hr"]
    fig, ax = plt.subplots(figsize=(16, 9))
    fig.subplots_adjust(left=0.07, right=0.84, top=0.80, bottom=0.17)
    ax.bar(t, vs, width=0.035, color="white", edgecolor=WATER_DARK, hatch="///", lw=1.0)
    ax.set_ylabel("Hourly rain (in), downtown-scaled")
    ax2 = ax.twinx()
    cum = np.cumsum(vs)
    ax2.plot(t, cum, color=WATER, lw=3.4)
    for k, c in [("2", MUTED), ("25", ALERT2), ("100", ALERT3)]:
        ax2.axhline(a14[k], color=c, lw=1.4, ls="--")
        ax2.text(t[-1], a14[k], f"  {k}-yr 24-hr {a14[k]:.2f} in", color=c, va="center", fontsize=13)
    ax2.set_ylabel("Cumulative (in)")
    ax2.spines["right"].set_visible(True)
    ax2.grid(False)
    import matplotlib.dates as mdates
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%-I %p" if sys.platform != "win32" else "%I %p"))
    fig.suptitle(f"Replay storm: New Year's Eve 2022, {daily['2022-12-31']:.2f} in downtown",
                 x=0.07, ha="left", y=0.95, fontsize=24, weight="bold", color=INK)
    fig.text(0.07, 0.86, "Nearly a 100-year, 24-hour rainfall at 17th & Folsom. 17 flooding reports to 311 "
             "within 600 m that day.", fontsize=15, color=INK)
    source_note(ax, "Daily total: GHCN-D USW00023272 SF Downtown (official). Hourly shape: SFO ASOS, scaled "
                "(derived, hatched). Thresholds: NOAA Atlas 14.")
    save_fig(fig, "replay_rain")


def forecast():
    stamp = dt.date.today().isoformat()
    for key, s in SITES.items():
        for model in ("gfs025", "ecmwf_ifs025"):
            d = getj("https://ensemble-api.open-meteo.com/v1/ensemble",
                     {"latitude": s["lat"], "longitude": s["lon"], "hourly": "precipitation",
                      "models": model, "forecast_days": 7, "timezone": "America/Los_Angeles"})
            d["_provenance"] = {"provenance": "official", "source": f"Open-Meteo ensemble API, model {model} "
                                "(NOAA GEFS / ECMWF ENS); CC BY 4.0", "retrieved_at": dt.datetime.now().isoformat(),
                                "role": "fallback for WeatherNext in get_forecast_rain"}
            json.dump(d, open(out(ROOT / "data" / "forecast" / f"ensemble_{key}_{model}_{stamp}.json"), "w"))
            ks = [k for k in d["hourly"] if k.startswith("precipitation")]
            tot = sorted(sum(x or 0 for x in d["hourly"][k]) / 25.4 for k in ks)
            print(f"  forecast {key} {model}: {len(ks)} members, 7-day total P10/P50/P90 = "
                  f"{tot[len(tot)//10]:.2f}/{tot[len(tot)//2]:.2f}/{tot[9*len(tot)//10]:.2f} in")
    plt = plt_setup()
    d = json.load(open(ROOT / "data" / "forecast" / f"ensemble_rain_gfs025_{stamp}.json"))
    t = [dt.datetime.fromisoformat(x) for x in d["hourly"]["time"]]
    fig, ax = plt.subplots(figsize=(16, 9))
    fig.subplots_adjust(left=0.07, right=0.95, top=0.80, bottom=0.17)
    for k in [k for k in d["hourly"] if k.startswith("precipitation")]:
        ax.plot(t, np.cumsum([(x or 0) / 25.4 for x in d["hourly"][k]]), color=WATER, alpha=0.35, lw=1.2)
    ax.set_ylabel("Cumulative rain (in)")
    fig.suptitle("Next 7 days at 17th & Folsom: every ensemble member", x=0.07, ha="left", y=0.95,
                 fontsize=24, weight="bold", color=INK)
    fig.text(0.07, 0.86, f"Snapshot {stamp}. Re-run the morning of the event; WeatherNext replaces this when "
             "access lands.", fontsize=15, color=INK)
    source_note(ax, "NOAA GEFS 0.25° (31 members) via Open-Meteo ensemble API.")
    save_fig(fig, "ensemble_fan")


# ----------------------------------------------------------------- terrain + maps
def _tiles_for(key):
    want = [i["url"].rsplit("/", 1)[-1] for i in rawj(f"dem_tiles_{key}.json")
            if "CA_SanFrancisco_B23" in (i["title"] or "")]
    paths = [p for p in glob.glob(str(RAW / "dem" / "*.tif")) if Path(p).name in want]
    if not paths:
        raise SystemExit(f"No DEM tiles for {key}; run stage_data.py --download-dem first")
    return paths


def hillshade(z, res, az=315, alt=45):
    gy, gx = np.gradient(z, res)
    slope = np.pi / 2 - np.arctan(np.hypot(gx, gy))
    aspect = np.arctan2(-gx, gy)
    a, b = np.radians(az), np.radians(alt)
    hs = np.sin(b) * np.sin(slope) + np.cos(b) * np.cos(slope) * np.cos(a - aspect)
    return np.clip(hs, 0, 1)


def terrain():
    import rasterio
    from rasterio.merge import merge
    from pyproj import Transformer
    from PIL import Image
    meta_all = {}
    for key, s in SITES.items():
        srcs = [rasterio.open(p) for p in _tiles_for(key)]
        crs = srcs[0].crs
        tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
        x0, y0 = tr.transform(s["bbox"][0], s["bbox"][1])
        x1, y1 = tr.transform(s["bbox"][2], s["bbox"][3])
        arr, transform = merge(srcs, bounds=(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)))
        z = arr[0].astype("float32")
        nod = srcs[0].nodata
        if nod is not None:
            z[z == nod] = np.nan
        prof = {"driver": "GTiff", "height": z.shape[0], "width": z.shape[1], "count": 1, "dtype": "float32",
                "crs": crs, "transform": transform, "compress": "lzw", "predictor": 3, "nodata": np.nan}
        with rasterio.open(out(ROOT / "data" / "terrain" / f"{key}_dem_1m.tif"), "w", **prof) as dst:
            dst.write(z, 1)
        zf = np.where(np.isnan(z), np.nanmin(z), z)
        zmin, zmax = float(np.nanmin(z)), float(np.nanmax(z))
        h16 = ((zf - zmin) / (zmax - zmin) * 65535).astype("uint16")
        Image.fromarray(h16).save(out(ROOT / "data" / "terrain" / f"{key}_heightmap16.png"))
        hs = hillshade(zf, abs(transform.a))
        Image.fromarray((hs * 255).astype("uint8")).save(out(ROOT / "data" / "terrain" / f"{key}_hillshade.png"))
        meta = {"site": s["name"], "crs": str(crs), "vertical": "NAVD88 meters (≈ MLLW - 0.018 m at SF)",
                "transform": list(transform)[:6], "width": int(z.shape[1]), "height": int(z.shape[0]),
                "res_m": abs(transform.a), "z_min_m": zmin, "z_max_m": zmax,
                "heightmap16": "z = z_min + (v / 65535) * (z_max - z_min)",
                "source": "USGS 3DEP 1 m CA_SanFrancisco_B23", "provenance": "official"}
        json.dump(meta, open(out(ROOT / "data" / "terrain" / f"{key}_terrain.json"), "w"), indent=1)
        meta_all[key] = (z, transform, crs)
        print(f"  terrain {key}: {z.shape[1]}x{z.shape[0]} m, {zmin*M_TO_FT:.1f}-{zmax*M_TO_FT:.1f} ft NAVD88")
    return meta_all


def _sfpuc_zone_clip(bbox):
    from shapely.geometry import shape, box, mapping
    z = rawj("sfpuc_100yr_flood_risk_zone_2022.geojson")
    g = shape(z["features"][0]["geometry"]).buffer(0)
    return g.intersection(box(*bbox))


def ground_truth():
    from shapely.geometry import mapping, Point
    for key, s in SITES.items():
        pts = rawj(f"sf311_flooding_{key}_replay.json")
        fc = {"type": "FeatureCollection", "features": [
            {"type": "Feature", "geometry": {"type": "Point", "coordinates": [float(p["long"]), float(p["lat"])]},
             "properties": {"time": p["requested_datetime"], "address": p.get("address"),
                            "kind": p.get("service_details"), "provenance": "official",
                            "source": "SF 311 vw6y-z8j6, service_subtype=Flooding"}}
            for p in pts if p.get("lat") and p.get("long")]}
        json.dump(fc, open(out(ROOT / "data" / "ground_truth" / f"sf311_{key}_replay.geojson"), "w"), indent=1)
        zc = _sfpuc_zone_clip(s["bbox"])
        json.dump({"type": "FeatureCollection", "features": [] if zc.is_empty else [
            {"type": "Feature", "geometry": mapping(zc),
             "properties": {"source": "SFPUC 100-Year Storm Flood Risk Zone (Jul 2022) jzu3-4yxp",
                            "provenance": "official"}}]},
                  open(out(ROOT / "data" / "ground_truth" / f"sfpuc_100yr_zone_{key}.geojson"), "w"))
        print(f"  ground truth {key}: {len(fc['features'])} 311 points, SFPUC zone area "
              f"{0 if zc.is_empty else zc.area:.2e} deg²")


def dry_controls(terr):
    """Pick 10 R2 dry-control points for the rain site BEFORE any modeling (commit them)."""
    from pyproj import Transformer
    from shapely.geometry import Point
    z, transform, crs = terr["rain"]
    s = SITES["rain"]
    zone = _sfpuc_zone_clip(s["bbox"])
    reports = [Point(f["geometry"]["coordinates"]) for f in
               json.load(open(ROOT / "data" / "ground_truth" / "sf311_rain_replay.geojson"))["features"]]
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    inv = ~transform
    med = float(np.nanmedian(z))
    rng = np.random.default_rng(20261025)
    cand = []
    for lon, lat in zip(rng.uniform(s["bbox"][0], s["bbox"][2], 4000), rng.uniform(s["bbox"][1], s["bbox"][3], 4000)):
        p = Point(lon, lat)
        if zone.buffer(0.0009).contains(p):          # ~80 m clear of the SFPUC zone
            continue
        if any(p.distance(r) < 0.0016 for r in reports):  # ~150 m clear of any 311 report
            continue
        x, y = tr.transform(lon, lat)
        c, r = inv * (x, y)
        r, c = int(r), int(c)
        if not (0 <= r < z.shape[0] and 0 <= c < z.shape[1]) or np.isnan(z[r, c]) or z[r, c] < med:
            continue
        cand.append((lon, lat, float(z[r, c])))
    chosen = [cand[0]] if cand else []
    while cand and len(chosen) < 10:   # farthest-point sampling for spread
        best = max(cand, key=lambda q: min((q[0]-c[0])**2 + (q[1]-c[1])**2 for c in chosen))
        chosen.append(best)
    fc = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [round(lo, 6), round(la, 6)]},
         "properties": {"id": f"D{i+1:02d}", "ground_ft_navd88": round(e * M_TO_FT, 1),
                        "rule": "outside SFPUC 100-yr zone (+~80 m), >150 m from any 311 report, above bbox median ground",
                        "chosen": dt.date.today().isoformat(), "seed": 20261025}}
        for i, (lo, la, e) in enumerate(chosen)]}
    json.dump(fc, open(out(ROOT / "data" / "ground_truth" / "dry_controls_rain.geojson"), "w"), indent=1)
    print(f"  dry controls: {len(chosen)} points (from {len(cand)} candidates)")


def maps(terr):
    plt = plt_setup()
    from pyproj import Transformer
    from shapely.ops import transform as stx
    import matplotlib.patches as mpatches
    # rain ground truth
    z, transform, crs = terr["rain"]
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    ext = [transform.c, transform.c + transform.a * z.shape[1], transform.f + transform.e * z.shape[0], transform.f]
    hs = hillshade(np.where(np.isnan(z), np.nanmin(z), z), abs(transform.a))
    fig, ax = plt.subplots(figsize=(16, 9))
    fig.subplots_adjust(left=0.02, right=0.72, top=0.86, bottom=0.04)
    ax.imshow(hs, cmap="gray", extent=ext, vmin=0, vmax=1.2, alpha=0.9)
    ax.imshow(z * M_TO_FT, cmap="Blues_r", extent=ext, alpha=0.25)
    zone = _sfpuc_zone_clip(SITES["rain"]["bbox"])
    if not zone.is_empty:
        zu = stx(lambda x, y, zz=None: tr.transform(x, y), zone)
        geoms = getattr(zu, "geoms", [zu])
        for g in geoms:
            xs, ys = g.exterior.xy
            ax.fill(xs, ys, facecolor="none", edgecolor=WATER_DARK, hatch="///", lw=1.8)
    for f in json.load(open(ROOT / "data" / "ground_truth" / "sf311_rain_replay.geojson"))["features"]:
        x, y = tr.transform(*f["geometry"]["coordinates"])
        on_st = (f["properties"]["kind"] or "").lower().startswith("on_street")
        ax.scatter(x, y, s=140 if on_st else 90, marker="o" if on_st else "s",
                   color=ALERT3 if on_st else ALERT2, edgecolor="white", lw=1.5, zorder=5)
    try:
        for f in json.load(open(ROOT / "data" / "ground_truth" / "dry_controls_rain.geojson"))["features"]:
            x, y = tr.transform(*f["geometry"]["coordinates"])
            ax.scatter(x, y, s=90, marker="^", color="#2e7d32", edgecolor="white", lw=1.2, zorder=5)
    except FileNotFoundError:
        pass
    sx, sy = tr.transform(SITES["rain"]["lon"], SITES["rain"]["lat"])
    ax.scatter(sx, sy, s=320, marker="+", color=INK, lw=3, zorder=6)
    ax.annotate("17th & Folsom", (sx, sy), xytext=(12, 10), textcoords="offset points", fontsize=15, weight="bold")
    ax.set_xticks([]); ax.set_yticks([]); ax.grid(False)
    for sp in ax.spines.values():
        sp.set_visible(False)
    fig.suptitle("Ground truth: New Year's Eve 2022, Mission District", x=0.02, ha="left", y=0.95,
                 fontsize=24, weight="bold", color=INK)
    leg = [mpatches.Patch(facecolor="none", edgecolor=WATER_DARK, hatch="///", label="SFPUC 100-yr flood zone"),
           plt.Line2D([], [], marker="o", ls="", color=ALERT3, ms=11, label="311 flooding, on street"),
           plt.Line2D([], [], marker="s", ls="", color=ALERT2, ms=9, label="311 flooding, on property"),
           plt.Line2D([], [], marker="^", ls="", color="#2e7d32", ms=9, label="dry controls (pre-registered)")]
    fig.legend(handles=leg, loc="center left", bbox_to_anchor=(0.73, 0.55), frameon=False, fontsize=14)
    fig.text(0.73, 0.22, "Terrain: USGS 3DEP 1 m hillshade.\n311: DataSF, Dec 30 2022 – Jan 1 2023.\n"
             "Zone: SFPUC, July 2022.\nNot a model output.", fontsize=12, color=MUTED, va="top")
    fig.savefig(out(A / "maps" / "rain_ground_truth.png"), dpi=120)
    print("  map rain_ground_truth")

    # coast elevation bands (ground elevation only; not a flood model)
    z, transform, crs = terr["coast"]
    ext = [transform.c, transform.c + transform.a * z.shape[1], transform.f + transform.e * z.shape[0], transform.f]
    zft = z * M_TO_FT + NAVD88_TO_MLLW_FT
    stack = json.load(open(ROOT / "data" / "derived" / "coastal_stack.json"))
    levels = [s[1] for s in stack["scenarios"]]
    hs = hillshade(np.where(np.isnan(z), np.nanmin(z), z), abs(transform.a))
    fig, ax = plt.subplots(figsize=(16, 9))
    fig.subplots_adjust(left=0.02, right=0.72, top=0.86, bottom=0.04)
    ax.imshow(hs, cmap="gray", extent=ext, vmin=0, vmax=1.2)
    cols = ["#cfe3f3", "#9cc3e4", "#5e9bd0", "#1b4f7a"]
    for lv, c in sorted(zip(levels, cols), reverse=True):
        ax.imshow(np.where(zft <= lv, 1.0, np.nan), cmap=__import__("matplotlib.colors", fromlist=["x"]).ListedColormap([c]),
                  extent=ext, alpha=0.75)
    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    sx, sy = tr.transform(-122.3940, 37.7953)
    ax.scatter(sx, sy, s=300, marker="+", color=INK, lw=3, zorder=6)
    ax.annotate("SHACK15 / Ferry Building", (sx, sy), xytext=(12, -22), textcoords="offset points",
                fontsize=15, weight="bold")
    ax.set_xticks([]); ax.set_yticks([]); ax.grid(False)
    for sp in ax.spines.values():
        sp.set_visible(False)
    fig.suptitle("Ground below each scenario's still-water level, Embarcadero", x=0.02, ha="left", y=0.95,
                 fontsize=24, weight="bold", color=INK)
    leg = [mpatches.Patch(color=c, label=f"ground ≤ {lv:.1f} ft  ({n.split('(')[0].strip()})")
           for (n, lv, _), c in zip(stack["scenarios"], cols)]
    fig.legend(handles=leg, loc="center left", bbox_to_anchor=(0.73, 0.58), frameon=False, fontsize=13)
    fig.text(0.73, 0.30, "Elevation bands only: not connectivity-\nchecked, no seawall, no waves.\n"
             "Bay water surface appears as lowest band.\nUSGS 3DEP 1 m; ft MLLW.", fontsize=12, color=MUTED, va="top")
    fig.savefig(out(A / "maps" / "coast_elevation_bands.png"), dpi=120)
    print("  map coast_elevation_bands")


STEPS = ["charts", "forecast", "terrain"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", choices=STEPS)
    a = ap.parse_args()
    steps = a.only or STEPS
    failed = []
    if "charts" in steps:
        for fn in (chart_kelvin, chart_coastal_stack, chart_replay_rain):
            try:
                fn()
            except Exception as ex:
                failed.append(fn.__name__); print(f"  ERROR {fn.__name__}: {ex}", file=sys.stderr)
    if "forecast" in steps:
        try:
            forecast()
        except Exception as ex:
            failed.append("forecast"); print(f"  ERROR forecast: {ex}", file=sys.stderr)
    if "terrain" in steps:
        try:
            terr = terrain()
            ground_truth()
            dry_controls(terr)
            maps(terr)
        except Exception as ex:
            import traceback; traceback.print_exc()
            failed.append("terrain")
    print(f"\nDone. failed: {failed or 'none'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
