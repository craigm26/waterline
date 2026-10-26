# Waterline: notes for Claude Code sessions

Waterline does street-level flood screening for San Francisco this El Niño winter. It stacks the tide, the Kelvin-wave anomaly, storm surge and rain on top of city lidar, and shows the result as a city-manager view on the web and an AR water line on iOS. It started as an entry for the Gemini 4 Argon hackathon (Oct 25, 2026), which Craig didn't attend. It's now a public v2 project. **Read `plan/v2-roadmap.md` first**, because it has the deliverables, the tide-date deadlines and the open questions.

## State as of Oct 26, 2026

- **Public repo** with Issues #1–7 left over from the hackathon split. Issues #1–3 (city view, agent activity UI, iteration strip) still apply. #4–5 and #7 were hackathon-day tasks, so re-scope them or close them.
- **Repo renamed** to `craigm26/waterline` on Oct 26.
- **City-manager site** (`site/index.html`, built with Claude Code Oct 26) is live at `https://craigmerry.com/waterline/`, listed on the craigmerry.com experiments page. It fetches NOAA CO-OPS + NWS live in the browser and falls back to `site/data/forecast.json`. Run it with `cd site && python3 -m http.server 8000`.
- **Build-day demo** (`demo/index.html`) is an ARCHIVE at `https://craigmerry.com/waterline/build-day/`: the page written before the Oct 25 Argon hackathon to guide a build day with Antigravity + Gemini 4 Argon, whose target was the city-manager site. The build day never happened. Its banner says so; never present its Argon claims as results anywhere.
- **Publish:** commit here, then in `~/projects/craigm26/personalsite` run `scripts/sync-waterline.sh` (site/ -> /waterline/, demo/ -> /waterline/build-day/), commit and push `master` (that push deploys). GitHub Pages is off.
- **WeatherNext 3 access approved Oct 25** for Craig's Google account. The table, schema, query and licensing caveat are in `plan/v2-roadmap.md`. **It's the last task, not the first.** NOAA is in: `scripts/refresh_live.py` pulls CO-OPS tide + NWS rain into `site/data/forecast.json`, run by hand; `scripts/build_city_data.py` packs the citywide analysis into `site/data/`. The scheduled refresh and the WeatherNext pull come after everything else.
- **iOS AR app:** 1.0 (1) marker mode in `ios/`, bundle `com.craigmerry.waterline` (registered Oct 26): live NOAA scenarios, help + about sheets, icon. Archive + TestFlight upload: `ios/archive_upload.sh` on the MacInCloud Mac. Anchoring math is in `plan/ar-anchoring.md`.

## This machine (Raspberry Pi 5)

- arm64 Linux. The Python geo stack installs from pip wheels: `pip install numpy rasterio shapely pyproj matplotlib pillow scipy "laspy[lazrs]"`. If a rasterio wheel is missing, install `apt install gdal-bin libgdal-dev` first.
- `scripts/render_watch.py` needs Playwright Chromium (arm64 is supported: `python -m playwright install --with-deps chromium`) and ffmpeg. Without a GPU expect about 10 minutes per run, so pass `--hotspots 2` while iterating.
- **This machine can't build iOS.** Write the Swift here, then compile on the MacInCloud Mac over SSH (rsync `ios/`, `~/bin/xcodegen generate`, `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`). There is no GitHub Actions job; CI and deploys don't use Actions. Signed archives and TestFlight uploads also go through MacInCloud; unlock the keychain in the same SSH connection as the archive. One TestFlight upload per working session.
- WeatherNext/BigQuery (last task): authenticate as Craig with `gcloud auth login` and `gcloud auth application-default login`, then `pip install google-cloud-bigquery`. Keep credentials out of git; `.env` is gitignored.

## Commands

```bash
cd site && python3 -m http.server 8000                 # city-manager site
python3 scripts/refresh_live.py --print                # NOAA tide + NWS rain -> site/data/forecast.json
python3 scripts/build_city_data.py                     # citywide analysis -> site/data/
cd demo && python3 -m http.server 8000                 # build-day demo (archive)
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
- `site/data/forecast.json`: NOAA forecast (CO-OPS tide + NWS rain; WeatherNext added last), schema `waterline.forecast.v1`
- `site/data/city.json`: top 500 drains, 50 low spots, crew zones, summary, schema `waterline.city.v1`

## Rules that don't bend

1. A water surface comes only from computed depth. Never draw or generate a flood image.
2. Provenance is visible everywhere: official data is solid, derived is outlined, assumed is hatched. A stress test is labeled as a stress test.
3. No number goes on screen until it's computed, and every number links to its source.
4. Every outbound action (alerts, work orders, adopter notices) is a draft that waits for a person. Nothing gets sent automatically.
5. It's a screening model, not HEC-RAS, and the UI says so.
6. Datums: CO-OPS 9414290 MLLW = 5.98 ft STND; NAVD88 zero = −0.06 ft MLLW; SF City Datum + 11.35 ft = NAVD88. Thresholds in ft MLLW: NWS minor 7.04, NOS minor 7.71, NOS moderate 8.64, NOS major 9.91.

## Writing

Commit messages, PR text and docs follow Craig's technical-writing voice: claim first, concrete, no hype words, few em-dashes, end on something runnable.
