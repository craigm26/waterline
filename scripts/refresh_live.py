#!/usr/bin/env python3
"""Pull NOAA tide and NWS rain for San Francisco into site/data/forecast.json.

Sources (both keyless, CORS-open, so the city page can also fetch them live):
  CO-OPS 9414290 San Francisco: 15-day high/low predictions, and 30 days of observed
    vs predicted water level for the anomaly (the El Nino / Kelvin-wave baseline).
  NWS gridpoint MTR/85,105 (17th & Folsom): quantitative precipitation and chance of rain,
    about 7 days out.

Every value keeps its source URL. The "with anomaly" tide is derived: today's 30-day mean
residual added to each predicted high, which assumes the anomaly holds. The page labels it so.

    python3 scripts/refresh_live.py            # writes site/data/forecast.json
    python3 scripts/refresh_live.py --print    # also prints the day table
"""
import argparse, datetime as dt, json, pathlib, statistics, urllib.request
from zoneinfo import ZoneInfo

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "site/data/forecast.json"
TZ = ZoneInfo("America/Los_Angeles")
STATION = "9414290"
GRID = "MTR/85,105"
UA = {"User-Agent": "waterline (https://craigmerry.com/waterline/)"}
COOPS = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"
# ft MLLW at 9414290 (CO-OPS / NWS flood thresholds; CLAUDE.md rule 6)
THRESHOLDS = {"nws_minor": 7.04, "nos_minor": 7.71, "nos_moderate": 8.64, "nos_major": 9.91}
DAYS = 15


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return json.load(r)


def coops(product, begin, end, **extra):
    q = dict(station=STATION, product=product, begin_date=begin.strftime("%Y%m%d %H:%M"),
             end_date=end.strftime("%Y%m%d %H:%M"), datum="MLLW", units="english",
             time_zone="lst_ldt", format="json", application="waterline", **extra)
    url = COOPS + "?" + "&".join(f"{k}={str(v).replace(' ', '%20')}" for k, v in q.items())
    return get(url), url


def anomaly(now):
    """Mean observed minus predicted over the last 30 days and the last 24 h, ft."""
    begin = now - dt.timedelta(days=30)
    obs, obs_url = coops("water_level", begin, now)
    pred, _ = coops("predictions", begin, now, interval=6)
    p = {r["t"]: float(r["v"]) for r in pred.get("predictions", [])}
    res = [(r["t"], float(r["v"]) - p[r["t"]]) for r in obs.get("data", []) if r.get("v") and r["t"] in p]
    if not res:
        raise SystemExit("CO-OPS returned no matched water levels")
    day_ago = (now - dt.timedelta(hours=24)).strftime("%Y-%m-%d %H:%M")
    return {"mean_30d_ft": round(statistics.fmean(v for _, v in res), 2),
            "mean_24h_ft": round(statistics.fmean(v for t, v in res if t >= day_ago), 2),
            "latest": {"t": res[-1][0], "residual_ft": round(res[-1][1], 2)},
            "samples": len(res), "source": obs_url}


def tides(now):
    end = now + dt.timedelta(days=DAYS)
    d, url = coops("predictions", now, end, interval="hilo")
    return [{"t": r["t"], "ft": float(r["v"]), "type": r["type"]} for r in d["predictions"]], url


def nws():
    url = f"https://api.weather.gov/gridpoints/{GRID}"
    g = get(url)["properties"]

    def spans(series):
        out = []
        for v in series["values"]:
            start, dur = v["validTime"].split("/")
            t0 = dt.datetime.fromisoformat(start)
            h = int(dur.removeprefix("PT").removesuffix("H")) if dur.startswith("PT") else 24 * int(dur[1:].split("D")[0])
            out.append((t0, h, v["value"] or 0))
        return out
    return spans(g["quantitativePrecipitation"]), spans(g["probabilityOfPrecipitation"]), g["updateTime"], url


def per_day(spans, how):
    """Split each span evenly by hour and aggregate per Pacific day (sum or max)."""
    acc = {}
    for t0, h, v in spans:
        for i in range(h):
            day = (t0 + dt.timedelta(hours=i)).astimezone(TZ).date().isoformat()
            x = v / h if how == "sum" else v
            acc[day] = acc.get(day, 0) + x if how == "sum" else max(acc.get(day, 0), x)
    return acc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--print", action="store_true")
    a = ap.parse_args()
    now = dt.datetime.now(TZ).replace(second=0, microsecond=0)
    anom = anomaly(now)
    hilo, hilo_url = tides(now)
    qpf, pop, nws_updated, nws_url = nws()
    rain = per_day(qpf, "sum")
    chance = per_day(pop, "max")
    base = anom["mean_30d_ft"]
    days = []
    for i in range(DAYS):
        day = (now + dt.timedelta(days=i)).date().isoformat()
        highs = [x for x in hilo if x["type"] in ("H", "HH") and x["t"].startswith(day)]
        if not highs:
            continue
        top = max(highs, key=lambda x: x["ft"])
        with_anom = round(top["ft"] + base, 2)
        days.append({
            "date": day,
            "high": {"t": top["t"], "predicted_ft": top["ft"], "with_anomaly_ft": with_anom},
            "over": [k for k, v in THRESHOLDS.items() if with_anom >= v],
            "rain_in": round(rain[day] / 25.4, 2) if day in rain else None,
            "rain_chance_pct": int(chance[day]) if day in chance else None,
        })
    doc = {
        "schema": "waterline.forecast.v1",
        "generated_at": now.isoformat(),
        "station": {"id": STATION, "name": "San Francisco, CA", "datum": "MLLW", "units": "ft"},
        "thresholds_ft_mllw": THRESHOLDS,
        "anomaly": anom,
        "days": days,
        "hilo": hilo,
        "sources": {
            "tide_predictions": hilo_url,
            "water_level": anom["source"],
            "rain": {"url": nws_url, "grid": GRID, "point": "17th & Folsom (37.7633, -122.4148)",
                     "updated": nws_updated, "note": "NWS quantitative precipitation, about 7 days out"},
        },
        "derived": "with_anomaly_ft = predicted high + 30-day mean residual (assumes the anomaly holds)",
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, indent=1))
    tmp.replace(OUT)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(days)} days, anomaly {base:+.2f} ft (30 d), {anom['mean_24h_ft']:+.2f} ft (24 h)")
    if a.print:
        for d in days:
            print(f"{d['date']}  high {d['high']['predicted_ft']:5.2f} -> {d['high']['with_anomaly_ft']:5.2f}  "
                  f"rain {d['rain_in'] if d['rain_in'] is not None else '-':>5} in  {','.join(d['over'])}")


if __name__ == "__main__":
    main()
