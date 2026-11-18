#!/usr/bin/env python3
"""Every San Francisco street inlet, for the app's Drains layer: ios/Waterline/Resources/sf_inlets.json.

places.json carries only the top 500 inlets, ranked. Standing on a flooded street you want the
grate at your corner, ranked or not, so the app also bundles all of them. The source is SFPUC's
inlet layer on DataSF (jtgq-b7c5), public domain (PDDL), so it can ship in the app and work
offline. Points that aren't a grate someone could clear (model-only pseudo drains, outlets,
tree wells, wet wells, culvert wing walls) are left out.

  python3 scripts/build_sf_inlets.py

Output: {"source", "as_of", "inlets": [[lon, lat, asset_id, type_code], ...]}, about 1 MB.
"""
import json
import pathlib
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "ios/Waterline/Resources/sf_inlets.json"
URL = "https://data.sf.gov/resource/jtgq-b7c5.json"
SKIP = ("Psuedo Drain", "outlet point", "Tree Well", "Wetwell", "Wing Wall")
# short codes keep the file small; the app turns them back into words
TYPES = {"Catch Basin Drain": "cb", "Storm Water Inlet Drain": "in", "Drop Inlet": "di", "Area Drain, used in Mission Bay": "ad",
         "Trench Drain": "tr", "Track Drain": "tk", "Curb Inlet: Drain w/ no grate": "ci"}


def main():
    rows, off = [], 0
    while True:
        q = urllib.parse.urlencode({"$select": "puc_maximo_asset_id,drain_type,location,data_as_of", "$limit": 50000, "$offset": off,
                                    "$order": "puc_maximo_asset_id"})
        req = urllib.request.Request(f"{URL}?{q}", headers={"User-Agent": "waterline-build"})
        page = json.load(urllib.request.urlopen(req, timeout=120))
        rows += page
        if len(page) < 50000:
            break
        off += 50000
    out, as_of = [], ""
    for r in rows:
        t = r.get("drain_type") or ""
        loc = (r.get("location") or {}).get("coordinates")
        if not loc or any(s in t for s in SKIP):
            continue
        out.append([round(loc[0], 6), round(loc[1], 6), r.get("puc_maximo_asset_id") or "", TYPES.get(t, "ot")])
        as_of = max(as_of, r.get("data_as_of") or "")
    OUT.write_text(json.dumps({"source": "SFPUC stormwater inlets, DataSF jtgq-b7c5, PDDL", "as_of": as_of[:10], "inlets": out},
                              separators=(",", ":")))
    print(f"{OUT.name}: {len(out)} of {len(rows)} inlets, {OUT.stat().st_size / 1e6:.2f} MB, as of {as_of[:10]}")


if __name__ == "__main__":
    main()
