# Waterline: notes for Claude Code sessions

Waterline does street-level flood screening for San Francisco this El Niño winter. It stacks the tide, the Kelvin-wave anomaly, storm surge and rain on top of city lidar, and shows the result as a city-manager view on the web and an AR water line on iOS. It started as an entry for the Gemini 4 Argon hackathon (Oct 25, 2026), which Craig didn't attend. It's now a public v2 project. **Read `plan/v2-roadmap.md` first**, because it has the deliverables, the tide-date deadlines and the open questions.

## State as of Oct 26, 2026

- **Public repo** with Issues #1–7 left over from the hackathon split. Issues #1–3 (city view, agent activity UI, iteration strip) still apply. #4–5 and #7 were hackathon-day tasks, so re-scope them or close them.
- **Story site** (`demo/index.html`) runs from a fresh clone (`cd demo && python3 -m http.server 8000`). It deploys to GitHub Pages at `https://craigm26.github.io/waterline-argon-hackathon/` through `.github/workflows/pages.yml`.
- **Next build:** the city-manager view in `site/`, served at `/city/`. Nothing is in `site/` yet.
- **WeatherNext 3 access approved Oct 25** for Craig's Google account. The table, schema, query and licensing caveat are in `plan/v2-roadmap.md`. Nothing ingests it yet; `scripts/refresh_live.py` is the first script to write.
- **iOS AR app:** not started. Anchoring math is in `plan/ar-anchoring.md`. The code will go in `ios/`.

## This machine (Raspberry Pi 5)

- arm64 Linux. The Python geo stack installs from pip wheels: `pip install numpy rasterio shapely pyproj matplotlib pillow scipy "laspy[lazrs]"`. If a rasterio wheel is missing, install `apt install gdal-bin libgdal-dev` first.
- `scripts/render_watch.py` needs Playwright Chromium (arm64 is supported: `python -m playwright install --with-deps chromium`) and ffmpeg. Without a GPU expect about 10 minutes per run, so pass `--hotspots 2` while iterating.
- **This machine can't build iOS.** Write the Swift here and let the `ios-build` GitHub Actions job (macOS runner) compile it: push, then `gh run watch`, read the log and fix. Device install happens on a Mac.
- WeatherNext/BigQuery: authenticate as Craig with `gcloud auth login` and `gcloud auth application-default login`, then `pip install google-cloud-bigquery`. Keep credentials out of git; `.env` is gitignored.

## Commands

```bash
cd demo && python3 -m http.server 8000                 # story site
python3 scripts/build_story_data.py                    # repack demo/ from data/ (needs geo stack)
python3 scripts/render_watch.py --tag iter0 --hotspots 2   # render stills + orbit.mp4 for critique
python3 scripts/loop_report.py                         # critiques -> score chart + iteration strip
gh release download data-v1 -D data/raw/citywide/dem   # citywide 1 m lidar DEM tiles (510 MB)
python3 scripts/fetch_lidar.py --crop NAME LAT LON HALF_M DEPTH   # new point-cloud crop from USGS EPT
```

## Contracts

Pages and apps read **only** these files; field names are listed in `CONTRIBUTING.md`. You can add fields, but never rename or remove them.
- `demo/story-data.json`: scenes, citywide drains/hotspots/311, tide, Kelvin, storm desk
- `demo/results.json`: computed run outputs, where each block shows only if its key exists
- `demo/lidar/*.bin`: 14 bytes per point (xyz float32 LE, m NAVD88; class u8; intensity u8)
- `site/data/forecast.json` (new): WeatherNext + CO-OPS forecast for the city view and the iOS app

## Rules that don't bend

1. A water surface comes only from computed depth. Never draw or generate a flood image.
2. Provenance is visible everywhere: official data is solid, derived is outlined, assumed is hatched. A stress test is labeled as a stress test.
3. No number goes on screen until it's computed, and every number links to its source.
4. Every outbound action (alerts, work orders, adopter notices) is a draft that waits for a person. Nothing gets sent automatically.
5. It's a screening model, not HEC-RAS, and the UI says so.
6. Datums: CO-OPS 9414290 MLLW = 5.98 ft STND; NAVD88 zero = −0.06 ft MLLW; SF City Datum + 11.35 ft = NAVD88. Thresholds in ft MLLW: NWS minor 7.04, NOS minor 7.71, NOS moderate 8.64, NOS major 9.91.

## Writing

Commit messages, PR text and docs follow Craig's technical-writing voice: claim first, concrete, no hype words, few em-dashes, end on something runnable.
