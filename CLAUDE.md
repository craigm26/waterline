# Waterline: notes for Claude Code sessions

Waterline does street-level flood screening for San Francisco this El Niño winter. It stacks the tide, the Kelvin-wave anomaly, storm surge and rain on top of city lidar, and shows the result as a city-manager view on the web and an AR water line on iOS. It started as an entry for the Gemini 4 Argon hackathon (Oct 25, 2026), which Craig didn't attend. It's now a public v2 project. **Read `plan/v2-roadmap.md` first**, because it has the deliverables, the tide-date deadlines and the open questions.

## State as of Oct 26, 2026

- **Public repo** with Issues #1–7 left over from the hackathon split. Issues #1–3 (city view, agent activity UI, iteration strip) still apply. #4–5 and #7 were hackathon-day tasks, so re-scope them or close them.
- **Repo renamed** to `craigm26/waterline` on Oct 26.
- **City-manager site** (`site/index.html`, built with Claude Code Oct 26) is live at `https://craigmerry.com/waterline/`, listed on the craigmerry.com experiments page. It fetches NOAA CO-OPS + NWS live in the browser and falls back to `site/data/forecast.json`. Run it with `cd site && python3 -m http.server 8000`.
- **Build-day demo** (`demo/index.html`) is an ARCHIVE at `https://craigmerry.com/waterline/build-day/`: the page written before the Oct 25 Argon hackathon to guide a build day with Antigravity + Gemini 4 Argon, whose target was the city-manager site. The build day never happened. Its banner says so; never present its Argon claims as results anywhere.
- **Publish:** commit here, then in `~/projects/craigm26/personalsite` run `scripts/sync-waterline.sh` (site/ -> /waterline/, demo/ -> /waterline/build-day/), commit and push `master` (that push deploys). GitHub Pages is off.
- **WeatherNext 3 access approved Oct 25** for Craig's Google account. The table, schema, query and licensing caveat are in `plan/v2-roadmap.md`. **It's the last task, not the first.** NOAA is in: `scripts/refresh_live.py` pulls CO-OPS tide + NWS rain into `site/data/forecast.json`, run by hand; `scripts/build_city_data.py` packs the citywide analysis into `site/data/`. The scheduled refresh and the WeatherNext pull come after everything else.
- **iOS app 1.1 (2), branch `ios-anywhere`, Nov 6:** the app reads the ground wherever you stand, with Here, Map and Water line tabs. It uses the bundled SF lidar grid (`scripts/build_ios_data.py`), plus NOAA tides from the nearest station, NWS rain and USGS EPQS anywhere in the US, and the LiDAR step measure, barometer floor height and compass arrows. Offline data packs (1 m ground, point clouds, raw LAZ/GeoTIFF) come from release `packs-v1` via `packs/manifest.json`, built by `scripts/build_packs.py` on the desktop. **Not compiled yet: compile on MacInCloud first.** See `ios/README.md`.
- **Nov 6 additions on `ios-anywhere` (cloud session):**
  - National layers: NWS river gauges (`api.water.noaa.gov/nwps`) and the FEMA NFHL flood zone at the spot. River flood stage becomes NAVD88 through the gauge datum; a datum of 0 is accepted only if the minor-stage elevation lands within 40 ft of the ground at the gauge.
  - Region packs (`regions/regions.json`, `scripts/build_regions.py`): 10 m ground + bowl grids from USGS 3DEP COGs for Sacramento, New Orleans, Miami, Norfolk, Charleston, Houston, NYC and Boston, downloaded in the app. The bowl is measured from open water and the padded region edge; behind a levee it's the basin depth (Natomas: 15.9 ft).
  - AR sky view: tags placed by true bearing (`worldAlignment = .gravityAndHeading`) at Street / Neighborhood / Watershed zoom. Gauges, the tide station, drains, low spots, higher ground and lidar scenes get tags; tapping a gauge shows NOAA's hydrograph.
- **Nov 6 evening, region parity (`scripts/build_region_layers.py`, `scripts/build_region_packs.py`, 1.1 (3)):** every region has SF's dataset set, grouped by place in Offline data. **Heavy builds run on the MacInCloud Mac in `~/waterline-build`, never on the Pi**: `screen -dmS wl caffeinate -i bash -c "./run.sh > build.log 2>&1"`, resumable, then upload the manifest's files with `gh release upload packs-v1`. Without a pack the phone fetches FEMA and USACE itself (`LiveLayers.swift`) and streams about 1 m ground from the USGS ImageServer (`TerrainView.swift`).
  - **City drains and service requests are read live from each city (`regions/city_sources.json`) and never copied into a pack:** most carry no redistribution license. Outside SF they don't move the risk level, because most feeds log drain requests, not floods.
  - **Scene heights are checked point by point against the DEM (`settle` in `build_region_packs.py`).** Block-wide medians gave false shifts of several metres. NYC's 2014 survey has unreliable ground labels, so its ground is relabelled against the DEM and the viewer says so.
- **Nov 6 night, 1.1 (4):** Offline data lists every dataset per place from `groups[].datasets` (`scripts/build_catalog.py`: `--probe` counts each source inside each place into `regions/coverage.json`; `regions/drain_programs.json` holds the volunteer programs, app links out only). The manifest is read network-first: a saved copy once hid the groups for up to 6 hours.
  - **Rain water estimate (`DrainageModel.swift`, `Drainage.swift`):** runs rain over the ground grid, fills depressions level and spills downhill. Rain is official (NWS forecast, nearest station); runoff 0.8 and drains 0.5 in/h are assumptions, shown on screen. The Map's Drainage layer and the AR levels both read it. Needs a ground grid: SF is bundled, elsewhere the 10 m pack. Water budget closes to 1.0000 on SF; no real flood has been compared to it yet.
  - **Markers (`POI.swift`, `POIDetail.swift`, `TagLayout.swift`):** every Map marker and AR tag opens one sheet: what it is, why it's there, its numbers with provenance marks, and its source. NOAA stages, impacts and crests (`GaugeDetail`) and USACE levee and pump records (`LiveLayers.nldRecord`) are read on open, so packs don't carry them. The AR view filters by distance (log slider, 330 ft to 40 mi) and type; tags that don't fit shrink to dots, and the list holds the rest. Layout has a standalone test case but touches and tracking need a device: XCUITest doesn't run on the headless Mac.
- **Nov 7, sources at the source:** every "Not in app yet" row became live where a public API exists. USGS stream gauges (OGC API `latest-continuous`, readings under 3 days old), CDEC river and reservoir stations (list in `regions/sensors.json` from `scripts/build_sensors.py`, readings live), NOAA Atlas 14 (10 and 100 year storms' heaviest hour through the rain water estimate; Map storm picker and AR levels), NOAA 2022 sea level rise at the tide station (2050 and 2100 intermediate, added to this month's highest tide), and USACE levees in SF. Sensors have no flood stages, so they never move the risk level. "At the source" now marks rows kept as links on purpose (all USGS 1 m tiles: too big for a phone).
- **Nov 7, 1.2 (1): one set of layers everywhere and what-if storms.** `Layers.swift` holds the switches (`@AppStorage("layersOff")`, rain water off by default) for the Map, AR chips, the streamed 3D ground and lidar scenes (`SceneLayers.swift` drapes markers, flood zones, levees, 311 dots and the rain water surface; taps open the marker sheet). Storm picker adds the next 3 days and Atlas 14's 24-hour 100- and 1000-year storms; the river's highest current-datum crest becomes a levee-failure what-if. The Here tab leads with "Next 3 days here" (NWS rain, the water it leaves, NOAA's river forecast peak, the tide). Rain water at a spot is the highest computed water surface within 15 m above the ground there: one grid cell is finer than a GPS fix (17th & Folsom read 0 at its own cell).
- **Nov 7, 1.3 (1): a water gauge for the street, and AR that plays it.** `WaterTimeline` (Drainage.swift) runs the bowl model hour by hour from the last 6 h of measured NWS rain through the 72 h forecast: runoff accrues at 80% of each hour's rain and working drains take 0.5 in an hour back out, also in dry hours, so water drains after a shower (the static model only ever fills). Atlas 14's 100- and 1000-year 24 h storms get the same timeline, alternating-block shaped (peak hour at hour 12), then a dry day. `WaterGauge.swift` charts it on the Here card with a 5 ft 9 in person for scale; what-ifs carry a red WHAT-IF badge. In AR the water rises into place (2.5 s), is murky and drifts, stands beside a staff gauge in feet and a 1.75 m person, and a play bar steps the timeline. AR look is untested on a device.
- **Nov 7, 1.4 (1): what stacks on a high tide.** `CoastStack.swift` per NOAA station: the king tide (highest hilo prediction in 12 months), monthly mean sea level with its linear trend and calendar-month mean removed (El Niño winters stand out on the Pacific: SF Feb 1998 +0.93, Mar 1983 +0.90, Oct 2026 +0.83 ft), and the record storm push = the peak hourly height around the datums `maxdate` minus the hourly prediction for that hour (both GMT; `maxtime` has no zone and disagrees between stations) minus that month's anomaly so El Niño isn't counted twice (SF 1983 1.2 ft, Battery 2012 8.9 ft). `ENSO` reads CPC's ONI text (ASO 2026 +2.46, strong El Niño). The coast card charts the layers as a staircase against the level that reaches the spot; AR scenario `coast-stack` raises them one at a time. Replaced the hard-coded SF "+3.07 ft Feb 1998" stress test that applied everywhere and the flat "+2 ft storm".
- **Next, for the Pi session:**
  1. ~~Compile~~ Done Nov 6 15:12: `ios-anywhere` @ 6531e46 builds clean on MacInCloud (unsigned). The cloud session compiles through the Pi using its own clone in `/tmp/wl-cloud` and a separate Mac folder, `~/waterline-ios-cloud`, so the Pi's working tree and `~/waterline-ios` are untouched. Next: run it on a device, then TestFlight 1.1 (2).
  2. ~~Region packs~~ Done Nov 6 15:33: built on the Pi (`/tmp/wl-cloud/regions-repo`) and uploaded to `packs-v1`. The 8 `*_grid.bin` files are byte-identical to the cloud build, and `packs/manifest.json` lists all 13 packs; every size matches the release. To rebuild: `python3 scripts/build_regions.py`, then `gh release upload packs-v1 dist/regions/*_grid.bin --clobber`, bump the pack `version`, and commit the manifest.
  3. On a device: Here at home (Sacramento area) should show the American/Sacramento River gauges, the FEMA zone, and the region-pack offer.
- **iOS 1.0 (1)** was marker mode in `ios/`, bundle `com.craigmerry.waterline` (registered Oct 26): live NOAA scenarios, help + about sheets, icon. Archive + TestFlight upload: `ios/archive_upload.sh` on the MacInCloud Mac. Anchoring math is in `plan/ar-anchoring.md`.

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
6. Datums: CO-OPS 9414290 MLLW = 5.98 ft STND, NAVD88 = 5.92 ft STND, so **ft MLLW = ft NAVD88 − 0.06** (a water level in MLLW is +0.06 in NAVD88; fixed repo-wide Nov 6, it was backwards); SF City Datum + 11.35 ft = NAVD88. Thresholds in ft MLLW: NWS minor 7.04, NOS minor 7.71, NOS moderate 8.64, NOS major 9.91.

## Writing

Commit messages, PR text and docs follow Craig's technical-writing voice: claim first, concrete, no hype words, few em-dashes, end on something runnable.
