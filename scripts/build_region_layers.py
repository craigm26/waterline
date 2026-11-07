"""Build each region's map and AR layers: dist/regions/<id>_layers.json, same shape as SF's places.json.

  hotspots    mapped street low spots, found the same way everywhere from the 10 m grid (ponds and
              channels filtered out). Unlike SF's list these aren't ranked with local 311 data unless
              the city publishes it, so they say where the ground is low, not where it has flooded.
  zone_rings  FEMA 1% annual chance flood zones (NFHL), dissolved. SF's equivalent is the SFPUC zone.
  levees      USACE National Levee Database alignments and floodwalls
  pumps       USACE pump stations

City drains and service requests aren't here: most carry no license to redistribute, so the app
reads them live from each city (regions/city_sources.json) and they're empty in this file.

Usage: python scripts/build_region_layers.py [--only sacramento miami] [--no-names]
Needs dist/regions/<id>_grid.bin from build_regions.py. Population comes from the 2020 census,
street names from OpenStreetMap (Nominatim, 1 request a second), cached in data/raw/names_<id>.json.
"""
import argparse, json, math, time, urllib.parse, urllib.request, zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "dist/regions"
RAW = ROOT / "data/raw"
UA = {"User-Agent": "waterline-data-build (https://github.com/craigm26/waterline)"}
NFHL = "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query"
NLD = "https://geospatial.sec.usace.army.mil/dls/rest/services/NLD/Public/FeatureServer"
WINDOW_M = 400          # widest depression the low-spot search looks for
MIN_DEPTH_M = 0.45      # 1.5 ft
MIN_AREA_M2 = 1500
MAX_AREA_M2 = 200_000    # about four city blocks; bigger is a field, a basin or a bypass, which the bowl already covers
MIN_PEOPLE_KM2 = 800    # census density around the spot, so it's somewhere people live
CENSUS = "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/Tracts_Blocks/MapServer/2/query"


def get(url, timeout=120, tries=4):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
                return json.load(r)
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(4 * (i + 1))


def paged(url, params, page=1000):
    out, off = [], 0
    while True:
        d = get(url + "?" + urllib.parse.urlencode({**params, "resultOffset": off, "resultRecordCount": page}))
        if "error" in d:
            raise RuntimeError(f"{url}: {d['error']}")
        fs = d.get("features", [])
        out += fs; off += len(fs)
        if not fs or not (d.get("exceededTransferLimit") or d.get("properties", {}).get("exceededTransferLimit")):
            return out


def envelope(b):
    return {"geometry": f"{b[0]},{b[1]},{b[2]},{b[3]}", "geometryType": "esriGeometryEnvelope", "inSR": 4326,
            "spatialRel": "esriSpatialRelIntersects", "outSR": 4326, "f": "geojson"}


def fema_rings(r):
    """1% zones dissolved and simplified to about 10 m, clipped to the region."""
    from shapely import make_valid
    from shapely.geometry import box, shape
    from shapely.ops import unary_union
    fs, W, S, E, N = [], *r["bbox"]
    # small boxes and pages: the service returns 500 on a city's worth of detailed polygons at once
    for i in range(math.ceil((E - W) / 0.06)):
        for j in range(math.ceil((N - S) / 0.06)):
            b = [W + i * 0.06, S + j * 0.06, min(E, W + (i + 1) * 0.06), min(N, S + (j + 1) * 0.06)]
            fs += paged(NFHL, {**envelope(b), "where": "SFHA_TF='T'", "outFields": "FLD_ZONE", "returnGeometry": "true", "maxAllowableOffset": 0.00005}, page=200)
    polys = []
    for f in fs:
        if f.get("geometry"):
            g = make_valid(shape(f["geometry"]))
            polys.append(g.buffer(0))
    u = unary_union(polys).intersection(box(*r["bbox"])).simplify(0.0001)
    rings = []
    for p in getattr(u, "geoms", [u]):
        if p.geom_type != "Polygon" or p.area < 2e-7:   # under about 2 ha
            continue
        for ring in [p.exterior, *p.interiors]:
            rings.append([[round(x, 5), round(y, 5)] for x, y in ring.coords])
    print(f"  FEMA: {len(fs)} polygons -> {len(rings)} rings, {sum(map(len, rings))} vertices")
    return rings


def levee_layers(r):
    levees, pumps = [], []
    for layer, kind in ((7, "levee"), (12, "floodwall")):
        for f in paged(f"{NLD}/{layer}/query", {**envelope(r["bbox"]), "where": "1=1", "outFields": "*", "returnGeometry": "true"}):
            g = f.get("geometry") or {}
            lines = g.get("coordinates", [])
            lines = lines if g.get("type") == "MultiLineString" else [lines]
            for line in lines:
                if len(line) >= 2:
                    levees.append({"kind": kind, "path": [[round(p[0], 5), round(p[1], 5)] for p in line[:: max(1, len(line) // 60)] + [line[-1]]]})
    for f in paged(f"{NLD}/4/query", {**envelope(r["bbox"]), "where": "1=1", "outFields": "*", "returnGeometry": "true"}):
        c = (f.get("geometry") or {}).get("coordinates")
        p = f.get("properties") or {}
        if c:
            name = next((p[k] for k in p if k.lower() in ("name", "structure_name", "pump_station_name") and p[k]), "Pump station")
            pumps.append({"name": str(name), "lon": round(c[0], 5), "lat": round(c[1], 5)})
    print(f"  levees: {sum(l['kind'] == 'levee' for l in levees)} lines, {sum(l['kind'] == 'floodwall' for l in levees)} floodwalls, {len(pumps)} pumps")
    return levees, pumps


def read_grid(p):
    raw = p.read_bytes(); i = raw.index(b"\n"); h = json.loads(raw[:i]); o = i + 1
    n = h["ground"]["bytes"]
    g = np.frombuffer(zlib.decompress(raw[o:o + n], -15), "<i2").reshape(h["rows"], h["cols"]).astype("float32")
    g[g == h["nodata_ground"]] = np.nan
    return g / 100, h


def low_spots(z, h, limit=500):
    """Local depressions up to WINDOW_M wide: a grey closing fills them, and the fill is the depth.
    This finds underpasses and street sags inside a levee basin too, where the priority-flood bowl
    is one basin-wide number. Candidates that look like water or channels are dropped."""
    from pyproj import Transformer
    from scipy import ndimage as ni
    res = h["res_m"]
    land = ~np.isnan(z)
    filled = np.where(land, z, np.nanmax(z))            # water reads high, so shores don't drain into it
    k = int(WINDOW_M / res) | 1
    depth = ni.grey_closing(filled, size=(k, k)) - filled
    depth[~land] = 0
    lab, n = ni.label(depth >= 0.15, structure=np.ones((3, 3)))
    tr = Transformer.from_crs(h["crs"], "EPSG:4326", always_xy=True)
    out = []
    for i, sl in enumerate(ni.find_objects(lab), 1):
        m = lab[sl] == i
        area = m.sum() * res * res
        if area < MIN_AREA_M2 or area > MAX_AREA_M2:
            continue
        d = depth[sl] * m
        dmax = float(d.max())
        if dmax < MIN_DEPTH_M or dmax > 12:             # deeper is a quarry or pit, not a street sag
            continue
        zz = z[sl][m]
        if (zz <= np.nanmin(zz) + 0.06).mean() > 0.25:  # flat bottom: lidar water surface (pond, lake, canal)
            continue
        bh, bw = m.shape
        if m.mean() < 0.3 or min(bh, bw) * res < 40:    # long and thin: channel or ditch
            continue
        r0, c0 = np.unravel_index(int(np.argmax(d)), d.shape)
        rr, cc = sl[0].start + r0, sl[1].start + c0
        lon, lat = tr.transform(h["x0"] + (cc + 0.5) * res, h["y0"] - (rr + 0.5) * res)
        out.append({"lon": round(lon, 6), "lat": round(lat, 6), "max_depth_m": round(dmax, 2), "area_m2": int(area)})
    out.sort(key=lambda s: -(s["max_depth_m"] * math.sqrt(s["area_m2"])))
    print(f"  low spots: {n} depressions, {len(out)} pass the filters")
    return out[:limit]


def people_per_km2(lat, lon):
    """2020 census population density of the blocks within 150 m, so a street-side block counts
    even when the sag itself sits in an empty highway block."""
    q = urllib.parse.urlencode({"geometry": f"{lon},{lat}", "geometryType": "esriGeometryPoint", "inSR": 4326, "distance": 150, "units": "esriSRUnit_Meter",
                                "outFields": "POP100,AREALAND", "returnGeometry": "false", "f": "json"})
    fs = get(f"{CENSUS}?{q}", 40).get("features", [])
    land = sum(f["attributes"]["AREALAND"] or 0 for f in fs)
    return sum(f["attributes"]["POP100"] or 0 for f in fs) / (land / 1e6) if land else 0


def name_spots(spots, rid, limit):
    """Keep spots where people live, and name them from OpenStreetMap. Open water, quarries and
    golf courses are dropped."""
    cache_p = RAW / f"names_{rid}.json"
    cache = json.loads(cache_p.read_text()) if cache_p.exists() else {}
    kept = []
    for s in spots:
        if len(kept) >= limit:
            break
        key = f"{s['lon']},{s['lat']}"
        c = cache.setdefault(key, {})
        if "people" not in c:
            c["people"] = people_per_km2(s["lat"], s["lon"])
        if c["people"] < MIN_PEOPLE_KM2:
            continue
        if "a" not in c:
            q = urllib.parse.urlencode({"format": "jsonv2", "lat": s["lat"], "lon": s["lon"], "zoom": 17, "addressdetails": 1})
            d = get(f"https://nominatim.openstreetmap.org/reverse?{q}", 30)
            c.update({"cat": d.get("category"), "type": d.get("type"), "a": d.get("address", {})})
            cache_p.parent.mkdir(parents=True, exist_ok=True)
            cache_p.write_text(json.dumps(cache))
            time.sleep(1.1)
        if c["cat"] in ("natural", "waterway", "water") or c["type"] in ("golf_course", "quarry", "basin", "reservoir", "pitch"):
            continue
        a = c["a"]
        road = a.get("road") or a.get("pedestrian") or a.get("footway")
        hood = a.get("neighbourhood") or a.get("suburb") or a.get("quarter") or a.get("city_district") or a.get("city")
        if road:
            kept.append({**s, "name": ", ".join(x for x in (road, hood) if x)})
    cache_p.parent.mkdir(parents=True, exist_ok=True)
    cache_p.write_text(json.dumps(cache))
    print(f"  kept {len(kept)} in places with {MIN_PEOPLE_KM2}+ people per km2")
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--no-names", action="store_true")
    ap.add_argument("--spots", type=int, default=50)
    a = ap.parse_args()
    from shapely.geometry import Point, Polygon
    regions = json.loads((ROOT / "regions/regions.json").read_text())["regions"]
    for r in regions:
        if a.only and r["id"] not in a.only:
            continue
        if (OUT / f"{r['id']}_layers.json").exists() and not a.only:
            continue
        print(r["id"], flush=True)
        z, h = read_grid(OUT / f"{r['id']}_grid.bin")
        try:
            rings = fema_rings(r)
            levees, pumps = levee_layers(r)
        except Exception as ex:     # a rerun retries this region
            print(f"FAILED {r['id']}: {ex!r}", flush=True)
            continue
        spots = low_spots(z, h)
        spots = spots[:a.spots] if a.no_names else name_spots(spots, r["id"], a.spots)
        drains, flood = [], []
        sources = {"zone": "FEMA National Flood Hazard Layer, 1% annual chance zones", "levees": "USACE National Levee Database",
                   "low_spots": "USGS 3DEP 10 m DEM; names (c) OpenStreetMap contributors, ODbL"}
        polys = [Polygon(x) for x in rings if len(x) >= 4]
        pts = np.array(flood) if flood else np.zeros((0, 2))
        cos = math.cos(math.radians(sum(r["bbox"][1::2]) / 2))
        for i, s in enumerate(spots, 1):
            s["rank"] = i
            s["in_zone"] = any(p.contains(Point(s["lon"], s["lat"])) for p in polys)
            near = np.hypot((pts[:, 0] - s["lon"]) * cos, pts[:, 1] - s["lat"]) * 111_320 <= 150 if len(pts) else []
            s["flood311"] = int(np.sum(near))
            s.setdefault("name", f"Low spot #{i}")
        doc = {"schema": "waterline.places.v1", "region": r["id"], "name": r["name"], "bbox": r["bbox"],
               "zone_label": "FEMA 1% flood zone", "drains": drains, "hotspots": spots, "flood311": flood,
               "zone_rings": rings, "flood311_total": len(flood), "levees": levees, "pumps": pumps, "sources": sources}
        p = OUT / f"{r['id']}_layers.json"
        p.write_text(json.dumps(doc, separators=(",", ":")))
        print(f"  -> {p.name} {p.stat().st_size / 1e6:.2f} MB; {len(drains)} drains, {len(flood)} reports", flush=True)
        for s in spots[:10]:
            print(f"     #{s['rank']:<3d}{s['max_depth_m'] * 3.28084:5.1f} ft {s['area_m2']:>8,d} m2 zone={int(s['in_zone'])} {s['lat']:.4f},{s['lon']:.4f} {s['name']}")


if __name__ == "__main__":
    main()
