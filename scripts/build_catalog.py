#!/usr/bin/env python3
"""Every dataset each place has, for the Offline data screen: packs/manifest.json `groups[].datasets`.

Each row says how the phone gets the data, one of:
  download  a pack from release packs-v1        (row has `pack`)
  bundled   ships inside the app (San Francisco)
  live      read from the source when online
  program   a volunteer drain program           (row has `url`)
  link      exists, not in the app yet          (row has `url`)
  missing   the source doesn't publish it

  python3 scripts/build_catalog.py --probe   count every live source inside each place -> regions/coverage.json
  python3 scripts/build_catalog.py           write the rows from coverage.json into the manifest

Counts come from the sources, so nothing on the screen is typed in by hand. A source that didn't
answer keeps its row and loses its number. build_region_packs.py calls attach() from its manifest step.
"""
import argparse, datetime, json, math, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COVERAGE = ROOT / "regions/coverage.json"
UA = {"User-Agent": "Waterline catalog (https://github.com/craigm26/waterline)"}
NFHL = "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query"
NLD = "https://geospatial.sec.usace.army.mil/dls/rest/services/NLD/Public/FeatureServer"
SF = "san-francisco"
GULF_ATLANTIC = {"new-orleans", "miami", "norfolk", "charleston", "houston", "nyc", "boston"}
COASTAL = GULF_ATLANTIC | {SF}

# Real sources the app doesn't read yet, by place. Every URL answered 200 on Nov 6, 2026.
ELSEWHERE = {
    "sacramento": [("water", "California river and reservoir sensors", "State stage, flow and storage readings, including sites NOAA doesn't carry.", "California DWR CDEC", "https://cdec.water.ca.gov/"),
                   ("maps", "California floodplain maps", "State Best Available Maps of 100, 200 and 500 year floodplains.", "California DWR", "https://gis.bam.water.ca.gov/bam/")],
    "houston": [("water", "Harris County rain and bayou sensors", "County network of rain and channel gauges.", "Harris County Flood Warning System", "https://www.harriscountyfws.org/")],
    "nyc": [("water", "FloodNet street sensors", "Street-level flood depth sensors in the five boroughs.", "FloodNet NYC", "https://www.floodnet.nyc/")],
    "norfolk": [("water", "StormSense water sensors", "Tide and flood sensors around Hampton Roads.", "StormSense", "https://www.stormsense.com/")],
}


def get(url, params, timeout=60):
    q = urllib.parse.urlencode(params)
    for wait in (30, 90, 0):
        try:
            with urllib.request.urlopen(urllib.request.Request(f"{url}?{q}", headers=UA), timeout=timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 or not wait:
                raise
            time.sleep(wait)


def fill(where, b):
    w, s, e, n = b
    return where.format(n=n, s=s, e=e, w=w)


def arcgis_count(url, where, b):
    p = {"where": where, "returnCountOnly": "true", "f": "json"}
    if b:
        p |= {"geometry": ",".join(map(str, b)), "geometryType": "esriGeometryEnvelope", "inSR": 4326, "spatialRel": "esriSpatialRelIntersects"}
    return get(url, p)["count"]


def feed_count(f, b):
    if f["type"] == "socrata":
        return int(get(f["url"], {"$select": "count(*) as n", "$where": fill(f["where"], b)})[0]["n"])
    return arcgis_count(f["url"], fill(f["where"], b), b if f["type"] == "arcgis" else None)


def km(a_lat, a_lon, b_lat, b_lon):
    x = math.radians(b_lon - a_lon) * math.cos(math.radians((a_lat + b_lat) / 2))
    return 6371 * math.hypot(x, math.radians(b_lat - a_lat))


def attempt(fn):
    try:
        return fn()
    except Exception as e:
        print("   no answer:", type(e).__name__, str(e)[:90])
        return None


def has_predictions(sid):
    day = datetime.date.today().strftime("%Y%m%d")
    r = get("https://api.tidesandcurrents.noaa.gov/api/prod/datagetter",
            {"product": "predictions", "application": "waterline", "station": sid, "datum": "MLLW", "units": "english", "time_zone": "gmt", "format": "json", "interval": "hilo", "begin_date": day, "range": 48})
    return bool(r.get("predictions"))


def tide_station(stations, lat, lon):
    """What the app lands on: the nearest of the three closest within 60 km that has predictions."""
    near = sorted(stations, key=lambda t: km(lat, lon, t["lat"], t["lng"]))
    for t in near[:3]:
        d = km(lat, lon, t["lat"], t["lng"])
        if d <= 60 and attempt(lambda: has_predictions(t["id"])):
            return {"name": t["name"], "km": round(d, 1)}
    return None


def gauge_count(lat, lon):
    """The app's filter: within 60 km of the spot, reporting stage in feet."""
    dlat, dlon = 60 / 111, 60 / (111 * math.cos(math.radians(lat)))
    r = get("https://api.water.noaa.gov/nwps/v1/gauges", {"bbox.xmin": lon - dlon, "bbox.ymin": lat - dlat, "bbox.xmax": lon + dlon, "bbox.ymax": lat + dlat, "srid": "EPSG_4326"})
    return sum(1 for g in r["gauges"] if km(lat, lon, g["latitude"], g["longitude"]) <= 60
               and ((g.get("status") or {}).get("observed") or {}).get("primaryUnit", "ft") == "ft")


def probe():
    m = json.loads((ROOT / "packs/manifest.json").read_text())
    stations = [s for s in get("https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json", {"type": "waterlevels"})["stations"] if s.get("tidal", True)]
    out = {"checked": datetime.date.today().isoformat(), "places": {}}
    for g in m["groups"]:
        w, s, e, n = b = g["bbox"]
        lat, lon = (s + n) / 2, (w + e) / 2
        print(g["id"])
        c = {"tide": tide_station(stations, lat, lon), "gauges": attempt(lambda: gauge_count(lat, lon))}
        c["fema"] = attempt(lambda: arcgis_count(NFHL, "SFHA_TF='T'", b))
        for name, layer in (("levees", 7), ("floodwalls", 12), ("pumps", 4)):
            c[name] = attempt(lambda: arcgis_count(f"{NLD}/{layer}/query", "1=1", b))
        live = g.get("live") or {}
        for name in ("drains", "reports"):
            if live.get(name):
                c[name] = attempt(lambda: feed_count(live[name], b))
        print("  ", c)
        out["places"][g["id"]] = c
    COVERAGE.write_text(json.dumps(out, indent=1) + "\n")


def n(v, one, many=None):
    return f"{v:,} {one if v == 1 else (many or one + 's')}"


def rows(g, packs, cov, places, programs):
    """The rows for one place, grouped by section in the order the app shows them."""
    rid, sf = g["id"], g["id"] == SF
    c = cov.get(rid, {})
    by_kind = {}
    for p in packs:
        by_kind.setdefault(p["id"], p)
    out = []

    def add(section, name, detail, source, access, **kw):
        out.append({"id": f"{rid}-{len(out)}", "section": section, "name": name, "detail": detail, "source": source, "access": access, **kw})

    def pack(section, pid, detail, source="USGS 3DEP lidar"):
        if pid in by_kind:
            add(section, by_kind[pid]["label"], detail, source, "download", pack=pid)

    G, M, W, S = "Ground and lidar", "Flood maps", "Water and weather", "Streets and city records"
    if sf:
        add(G, "Ground, 5 m", "Citywide ground height and depth to the nearest spill point, offline.", "USGS 3DEP lidar", "bundled")
        pack(G, "sf-ground-1m", "Ground to the inch on land at or below 30 ft, offline.")
        pack(G, "sf-lidar-scenes", "Orbit the block in the app and raise the water.")
        pack(G, "raw-laz", "The same places as LAZ files, for other lidar apps.")
        pack(G, "raw-dem", "5 m citywide, plus 1 m around the Ferry Building and 17th & Folsom.")
        pack(G, "raw-dem-1m", "The four USGS 1 m tiles that cover the city.")
    else:
        pack(G, f"region-{rid}", "Ground height offline, and how deep water can stand at each spot (derived from the lidar).")
        pack(G, f"{rid}-ground-1m", "Ground to the inch on land at or below 30 ft, offline.")
        pack(G, f"{rid}-scenes", "Orbit the block in the app and raise the water.")
        pack(G, f"{rid}-laz", "The same places as LAZ files, for other lidar apps.")
        pack(G, f"{rid}-dem", "10 m citywide, plus 1 m around the landmark and top low spot.")
    add(G, "Ground at this block, about 1 m", "Streamed for the 3D ground view on the Here tab.", "USGS 3DEP elevation service", "live")
    add(G, "Ground at this spot", "Used when no download covers the spot.", "USGS Elevation Point Query", "live")
    if g.get("usgs_1m"):
        u = g["usgs_1m"]
        add(G, f"All {u['tiles']} USGS 1 m tiles", f"The full citywide survey, {u['bytes'] / 1e9:.1f} GB. Download it from USGS.", "USGS National Map", "link", url=u["url"])

    if sf:
        add(M, "SFPUC 100-year storm flood map", "The city's own flood zone, on the Map.", "SFPUC via DataSF", "bundled")
        add(M, "FEMA flood zone at this spot", "The zone for the spot you're checking.", "FEMA NFHL", "live")
    else:
        pack(M, f"{rid}-layers", "FEMA zones, any levees and pumps, and mapped low spots together, offline.", "FEMA, USACE, Waterline low spots")
        v = c.get("fema")
        add(M, "FEMA flood zones", (f"{n(v, 'high-risk zone')} in this area. " if v is not None else "") + "Loaded around you without the pack.", "FEMA NFHL", "live")
    add(M, "Rainfall frequency", "How much rain a 10, 100 or 1000 year storm brings at a spot.", "NOAA Atlas 14", "link", url="https://hdsc.nws.noaa.gov/pfds/")
    if rid in COASTAL:
        add(M, "Sea level rise scenarios", "Mapped inundation at each foot of sea level rise.", "NOAA Office for Coastal Management", "link", url="https://coast.noaa.gov/slr/")
    if rid in GULF_ATLANTIC:
        add(M, "Hurricane storm surge risk", "Worst-case surge depth for each hurricane category.", "NOAA National Hurricane Center", "link", url="https://www.nhc.noaa.gov/nationalsurge/")
    for sec, name, detail, source, url in ELSEWHERE.get(rid, []):
        if sec == "maps":
            add(M, name, detail, source, "link", url=url)

    t = c.get("tide")
    if t:
        add(W, "Tide and water level", f"Nearest station {t['name']}, {t['km'] * 0.621371:.0f} mi from the city center.", "NOAA CO-OPS", "live")
    else:
        add(W, "Tide and water level", "No station with tide predictions within 37 mi of the city center. Spots closer to one still get it.", "NOAA CO-OPS", "live")
    v = c.get("gauges")
    add(W, "River gauges", (f"{n(v, 'gauge')} within 37 mi, with flood stages and forecasts." if v else "None within 37 mi." if v == 0 else "With flood stages and forecasts."), "NOAA National Water Prediction Service", "live")
    add(W, "Rain forecast", "Hourly forecast for the spot you're checking.", "National Weather Service", "live")
    est = "Where rain would stand on the Map and in the camera, with drains working or blocked. Computed from the ground and rain, with assumed drain and runoff rates."
    if sf:
        add(W, "Rain water estimate", est, "Waterline, from NWS rain and USGS ground", "bundled")
    else:
        add(W, "Rain water estimate", est + " Uses Ground and bowls, 10 m.", "Waterline, from NWS rain and USGS ground", "download", pack=f"region-{rid}")
    add(W, "USGS stream gauges", "Stage and flow history for rivers and creeks.", "USGS Water Data", "link", url="https://api.waterdata.usgs.gov/")
    for sec, name, detail, source, url in ELSEWHERE.get(rid, []):
        if sec == "water":
            add(W, name, detail, source, "link", url=url)

    a = programs.get(rid)
    if a:
        if a["status"] == "none":
            add(S, "Adopt a drain", a["detail"], a["operator"], "missing", **({"url": a["url"]} if a["url"] else {}))
        else:
            add(S, a["name"], a["detail"], a["operator"], "program", url=a["url"])
    if sf:
        pl = places
        add(S, "Worst storm drains", f"{n(len(pl['drains']), 'drain')} ranked citywide by how much water can stand over them.", "DataSF, Waterline ranking", "bundled")
        add(S, "Street low spots", f"The {len(pl['hotspots'])} worst, measured from the lidar.", "Derived by Waterline", "bundled")
        add(S, "Past flooding reports", f"{n(pl['flood311_total'], '311 report')}.", "DataSF 311", "bundled")
        add(S, "Levees and pumps", "Mapped nationally. San Francisco's Map doesn't show them yet.", "USACE National Levee Database", "link", url="https://levees.sec.usace.army.mil/")
    else:
        lv, fw, pu = c.get("levees"), c.get("floodwalls"), c.get("pumps")
        if (lv, fw, pu) == (0, 0, 0):
            detail = "None in the national database for this area. The app still checks as you move."
        elif None in (lv, fw, pu):
            detail = "Tagged on the Map and in the camera."
        else:
            detail = ", ".join(n(v, name) for v, name in ((lv, "levee segment"), (fw, "floodwall"), (pu, "pump station")) if v) + " mapped here. Tagged on the Map and in the camera."
        add(S, "Levees, floodwalls and pumps", detail, "USACE National Levee Database", "live")
        add(S, "Street low spots", "Mapped from the lidar and included in Map and AR layers.", "Derived by Waterline", "download", pack=f"{rid}-layers")
        live = g.get("live") or {}
        d = live.get("drains")
        if d:
            v = c.get("drains")
            note = f" {d['note']}." if d.get("note") else ""
            add(S, "Storm drains", (f"{n(v, 'drain')} in this area. " if v is not None else "") + "Read from the city near you, never copied." + note, f"{g['name']} open data", "live")
        if rid == "sacramento":
            add(S, "City of Sacramento storm drains", "The city doesn't publish its inlets, so downtown shows none.", "City of Sacramento", "missing")
        r = live.get("reports")
        if r:
            v = c.get("reports")
            add(S, live.get("reports_label") or "Service requests", (f"{n(v, 'record')} in this area. " if v is not None else "") + "They add context and don't change the risk level.", f"{g['name']} open data", "live")
    return out


def attach(m):
    """Write every place's rows into the manifest dict."""
    cov = json.loads(COVERAGE.read_text())
    places = json.loads((ROOT / "ios/Waterline/Resources/places.json").read_text())
    programs = json.loads((ROOT / "regions/drain_programs.json").read_text())
    for g in m["groups"]:
        g["datasets"] = rows(g, [p for p in m["packs"] if p.get("group") == g["id"]], cov["places"], places, programs)
        if g["id"] in programs:
            g["adopt"] = programs[g["id"]]
    m["catalog_checked"] = cov["checked"]


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true")
    a = ap.parse_args()
    if a.probe:
        probe()
    mp = ROOT / "packs/manifest.json"
    m = json.loads(mp.read_text())
    attach(m)
    mp.write_text(json.dumps(m, indent=1))
    for g in m["groups"]:
        k = {}
        for d in g["datasets"]:
            k[d["access"]] = k.get(d["access"], 0) + 1
        print(f"{g['id']:15} {len(g['datasets']):3} datasets {k}")
