# Contributing to Waterline

Built for the Gemini 4 Argon hackathon (SHACK15, Sun Oct 25 2026), **Problem Statement Two: render → watch → critique → fix**. Start with [`plan/track2-loop.md`](plan/track2-loop.md); it has the loop, the rubric and the work split.

## Run the demo (2 minutes, no Python packages needed)

```bash
git clone https://github.com/craigm26/waterline-argon-hackathon
cd waterline-argon-hackathon/demo
python -m http.server 8000        # then open http://localhost:8000
```

Everything the page needs is committed: `story-data.json`, the lidar scenes in `demo/lidar/*.bin`, and the images in `demo/img/`. It must be served over http (not `file://`).

## Run the render harness (what Argon "watches")

```bash
pip install playwright pillow && python -m playwright install chromium
python scripts/render_watch.py --tag iter0     # → renders/iter0/{*.png, orbit.mp4, manifest.json}
```

`ffmpeg` is needed for `orbit.mp4`. With a GPU it takes a minute or two; with software rendering it takes about 10.

## Rebuilding data (optional; only if you change the analysis)

```bash
python -m venv .venv && . .venv/bin/activate
pip install numpy rasterio shapely pyproj matplotlib pillow scipy "laspy[lazrs]"
python scripts/build_story_data.py               # repacks demo/ from data/derived + data/lidar
```

The raw downloads (`scripts/stage_data.py`, `download_citywide.py`) hit NOAA, USGS and DataSF and are already done. Their outputs are committed under `data/`.

## The contracts (don't break these)

The page reads **only** these files. Then Argon can regenerate the page without touching the data, and the data can change without breaking the page.

| File | Producer | Consumer | Shape |
|---|---|---|---|
| `demo/story-data.json` | `scripts/build_story_data.py` | page | lidar scenes, citywide drains/hotspots/311, tide, storm desk |
| `demo/results.json` | Argon runs on the day | page | see `demo/results.example.json`; each block shows only if its key exists |
| `demo/lidar/*.bin` | `scripts/fetch_lidar.py` | page | 14 bytes per point: x, y, z float32 LE (m, z NAVD88) + class uint8 + intensity uint8 |
| `renders/iterN/manifest.json` | `scripts/render_watch.py` | Argon critique | frames + on-screen numbers + page errors |
| `renders/iterN/critique.json` | Argon (prompt §9b) | fix step, `loop_report.py` | schema in `plan/track2-loop.md` |

If you need a new field, add it; don't rename or remove one.

## How we work on the day

- Branch per workstream (`viz/…`, `loop/…`, `data/…`, `video/…`), PR into `main`, and merge your own PR once the demo still loads. No reviews required; speed matters.
- Open an issue for anything blocking; workstream issues are labeled.
- **Honesty rules (from the README) apply to every PR:** water surfaces come only from computed depth; official = solid, derived = outlined, assumed = hatched; a stress test is labeled; no number on screen before it's computed.
- Big binaries: keep any single file under 20 MB. Footage goes in `demo/media/` as compressed MP4 (`ffmpeg -i in.mov -vf scale=1280:-2 -c:v libx264 -crf 26 -an out.mp4`).

## Licenses

Code: MIT (`LICENSE`). Data keeps its source terms: NOAA and USGS 3DEP are US public domain; DataSF datasets (SFPUC drains, 311, flood maps) are under DataSF's open data terms. The 311 photos are public records; the copies shown on the page (`assets/nye311/`) have license plates blurred.
