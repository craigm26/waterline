#!/usr/bin/env python3
"""Station lists for sensor networks with no search by location: regions/sensors.json.

The app reads readings live from each network. It needs only where the stations are, and CDEC
(California DWR) publishes that as an HTML search page, not an API. This keeps active stations that
report river stage (sensor 1), flow (20) or reservoir storage (15) within 40 km of each California
place, and build_catalog.py copies the list into packs/manifest.json under `sensors`.

  python3 scripts/build_sensors.py
"""
import html, json, re, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "regions/sensors.json"
UA = {"User-Agent": "Waterline sensors (https://github.com/craigm26/waterline)"}
CALIFORNIA = {"sacramento", "san-francisco"}
MARGIN = 0.4   # degrees past the place's box, about 40 km


def cdec_search(sensor, b):
    w, s, e, n = b
    q = {"sta": "", "sensor_chk": "on", "sensor": sensor, "collect": "NONE SPECIFIED", "dur": "", "active_chk": "on", "active": "Y",
         "loc_chk": "on", "lon1": w, "lon2": e, "lat1": s, "lat2": n, "elev1": -5, "elev2": 99000, "nearby": "",
         "basin": "NONE SPECIFIED", "hydro": "NONE SPECIFIED", "county": "NONE SPECIFIED", "agency_num": "", "display": "sta"}
    url = "https://cdec.water.ca.gov/dynamicapp/staSearch?" + urllib.parse.urlencode(q)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=90) as r:
        page = r.read().decode("utf-8", "replace")
    out = []
    for row in re.findall(r"<tr>(.*?)</tr>", page, re.S):
        cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        if len(cells) >= 6 and re.fullmatch(r"[A-Z0-9]{3}", cells[0]):
            try:
                out.append({"id": cells[0], "name": cells[1], "lon": round(float(cells[4]), 5), "lat": round(float(cells[5]), 5)})
            except ValueError:
                pass
    return out


def main():
    m = json.loads((ROOT / "packs/manifest.json").read_text())
    out = json.loads(OUT.read_text()) if OUT.exists() else {}
    for g in m["groups"]:
        if g["id"] not in CALIFORNIA:
            continue
        w, s, e, n = g["bbox"]
        b = (w - MARGIN, s - MARGIN, e + MARGIN, n + MARGIN)
        st = {}
        for sensor, kind in (("1", "river"), ("20", "river"), ("15", "reservoir")):
            for x in cdec_search(sensor, b):
                if x["id"] not in st or kind == "reservoir":
                    st[x["id"]] = x | {"kind": kind}
        out.setdefault(g["id"], {})["cdec"] = sorted(st.values(), key=lambda x: x["id"])
        print(g["id"], len(st), "CDEC stations")
    OUT.write_text(json.dumps(out, indent=1) + "\n")


if __name__ == "__main__":
    main()
