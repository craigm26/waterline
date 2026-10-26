# Waterline v2: after the hackathon

**Decision:** I missed the Oct 25 event, so Waterline continues as a public project with two deliverables. The first is a city-manager view on the web. The second is an AR app for iOS that works at the Ferry Building on a real king tide. WeatherNext 3 access was approved on Oct 25, so it replaces the GEFS/ECMWF fallback as the forecast layer.

The hackathon work isn't wasted. The data, the lidar, the drain ranking validated against 311, the Storm Desk script and the render → watch → critique → fix loop are all still the foundation. What changes is the audience: before, it was judges watching a 3-minute demo; now it's a city manager opening a URL in December, and a person standing on the seawall holding a phone.

## The calendar decides the order

The tide sets the deadlines, not us. Each date below is a real predicted high tide at station 9414290, and each one is a field test we can't move:

| Date | Predicted high (ft MLLW) | What has to work by then |
|---|---|---|
| **Nov 25** | 7.03 | AR app on a device at the Ferry Building, first field test against real water |
| **Dec 24, 10:37 AM** | 7.23 | The filmed demo: AR on the seawall + the city view running a live Storm Desk |
| Jan 21 | 7.11 | Second season test, during peak El Niño rainfall |

The live gauge has been running about +1 ft above prediction this October because of the Kelvin wave. So each of these tides should come in higher than the table says, and the app gets checked against what actually happens.

## Deliverable 1: city-manager view (web)

**Where:** `site/` in this repo, published at `https://craigmerry.com/waterline/city/`. The story page in `demo/` is `https://craigmerry.com/waterline/`, listed on the craigmerry.com experiments page. This repo is the source of truth; `scripts/sync-waterline.sh` in the `personalsite` repo copies `demo/` and `site/` into `public/waterline/`, and a push to personalsite `master` deploys it. There is no GitHub Pages deploy any more.

**What the city manager sees first:** the next 15 days of rain and tide for San Francisco on one strip, with WeatherNext p50/p90 rain against the predicted tide plus today's measured anomaly. Then the worst low spots for that forecast on a 3D map. Their first question is "do I need to do anything this week?", and the first screen answers it.

**Panels, in priority order:**
1. **Forecast strip:** NOAA first: CO-OPS predicted tide + live residual at 9414290, and NWS rain (the api.weather.gov hourly QPF grid for SF, plus NBM where it adds percentiles), with NOAA thresholds drawn as lines. WeatherNext 3 `total_precipitation_1hr_{p50,p90}` is added last, as a second rain source beside NWS.
2. **3D map:** citywide drains (top 500), 50 street low spots, 26k past 311 flooding reports, and a lidar drill-down per hotspot. The existing Act 7 code is the starting point.
3. **Storm Desk:** the 72-hour playbook (`citywide.storm_desk`). It starts as a replay, then becomes a live run triggered when the forecast crosses a threshold.
4. **Briefing export:** the drafted brief and alerts (EN/ES/ZH) as text the manager can copy. Approval stays with a person: the page never sends anything.

**Data refresh, in two steps:**
1. **NOAA, on demand (now).** `scripts/refresh_live.py` pulls CO-OPS (tide predictions, water level, residual) and NWS (`api.weather.gov` gridpoint QPF for SF), and writes `site/data/forecast.json`. Every number carries its source URL and fetch time. You run it by hand, then sync and push the site. Both APIs are free, keyless and CORS-open, so the city view can also fetch the tide live in the browser the way the story page already does.
2. **Scheduled job, last task of v2.** After everything else ships, run `refresh_live.py` on a schedule (Pi cron or a systemd timer, nightly plus every 6 h in storm weeks), then add the WeatherNext pull to it. It runs on the Pi as my Google account, so it doesn't depend on a service account. Until this step lands, `forecast.json` shows its fetch time and the page says how old it is.

### WeatherNext 3: what we have

- **Access:** subscribe to the WeatherNext 3 BigQuery Analytics Hub listing (`weathernext_3_1a067c1e929`) from a GCP project while signed in as the approved account. The tables then appear linked in a dataset in that project.
- **Table for us:** `weathernext_3_0_0_0p1deg`. It has one row per `init_time` × 0.1° cell, with `geography_polygon` and a repeated `forecast` record (`time`, `hours`). Variables come as `_mean/_p10/_p25/_p50/_p75/_p90`. We use `total_precipitation_1hr_*` (m, ×1000 → mm), `mean_sea_level_pressure_*`, and `u/v_component_of_wind_10m_*` for setup and surge context.
- **Cadence:** 6-hourly inits to 360 h, and hourly interim inits to 48 h.
- **BigQuery only has statistics.** The 64-member ensemble is in GCS as Zarr. We need members only if we want per-member flood maps; p50/p90 is enough for v2.
- **Earth Engine:** `projects/gcp-public-data-weathernext/assets/weathernext_3_0_0_0p05deg` holds only 2 m temperature and dewpoint station heads, so it's not useful for rain.
- **No 2022 replay:** history starts in 2026, so the NYE-2022 validation stays on observed rain.

```sql
SELECT t.init_time, f.time AS valid_time, f.hours,
       f.total_precipitation_1hr_p50 * 1000 AS rain_mm_p50,
       f.total_precipitation_1hr_p90 * 1000 AS rain_mm_p90
FROM `PROJECT.DATASET.weathernext_3_0_0_0p1deg` AS t, t.forecast AS f
WHERE t.init_time = (SELECT MAX(init_time) FROM `PROJECT.DATASET.weathernext_3_0_0_0p1deg`
                     WHERE init_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY))
  AND ST_INTERSECTS(t.geography_polygon, ST_GEOGFROMTEXT('POINT(-122.4148 37.7633)'))  -- 17th & Folsom
ORDER BY f.hours;
```

**Licensing (check before publishing numbers):** historic data is CC BY 4.0, which only needs attribution. **Real-time** data falls under the GDM Real-Time Weather Forecasting Experimental Data Terms of Use. Read those terms for redistribution before the public page shows live WeatherNext values. If they don't allow it, the public page shows a derived product (for example "rain above the 17th & Folsom trigger: likely / possible / unlikely") or falls back to NOAA NBM, and the raw values stay on the Pi.

## Deliverable 2: AR app (iOS)

**What it does:** you stand at the Ferry Building, point the phone at the seawall, and see the water line for a scenario drawn at true height on the real world: today's predicted high, + Kelvin baseline, + storm, + stress test. LiDAR occlusion hides the water behind people and bollards. The scenario levels come from the same JSON contracts the city view uses, so the app and the page always agree.

**Stack:** SwiftUI + RealityKit, with ARCore Geospatial terrain anchors for absolute height. Plain ARKit only knows height relative to where the session started, which is exactly the error we can't afford here. Then a relative offset Δ = (W − 0.06) − G_P, as worked out in `plan/ar-anchoring.md`. Scene reconstruction (`sceneReconstruction = .mesh`) handles occlusion on LiDAR iPhones.

**The constraint the Pi can't remove:** iOS apps build only with Xcode on macOS. The Pi session can write Swift, but it can't compile, sign or install it. The workflow:
- **Compile check without a Mac:** a GitHub Actions `macos-15` job runs `xcodebuild build` for the simulator (unsigned) on every push. The Pi session pushes, reads the Actions log and fixes errors, so CI acts as its compiler.
- **Device install: the MacInCloud Mac**, over SSH from the Pi (the same headless loop the other iOS apps use: rsync source, `~/bin/xcodegen generate`, `xcodebuild`). Signing uses the existing Apple Developer team, so builds go to TestFlight. There's no App Store Connect record for Waterline yet: creating one is Craig's call, done once and on its own. TestFlight uploads are a budget (about 20 per version per day), so batch changes into one upload per session and use `CODE_SIGNING_ALLOWED=NO` builds on MacInCloud or CI as the free compile check.
- **Field validation is the real test:** on Nov 25 we film the phone next to a tape-measure reading against a fixed seawall mark at the tide-gauge time. Then the AR line has to sit within ±0.2 ft of the real water. If it's off, we fix the anchor math before Dec 24.

## Milestones

| By | Done when |
|---|---|
| Oct 31 | Story site live at craigmerry.com/waterline/; `refresh_live.py` writes NOAA tide + NWS rain to `forecast.json` |
| Nov 7 | `site/` city view MVP at /waterline/city/: forecast strip (NOAA) + 3D map + hotspot drill-down, refreshed by hand |
| Nov 14 | iOS project in `ios/` building in CI; geospatial anchor + water plane on a device at home (test plane at a known height) |
| **Nov 25** | **Field test 1 at the Ferry Building**; Storm Desk replay in the city view |
| Dec 12 | Storm Desk live run against a real forecast; alerts drafted; render loop (`render_watch.py`) used to critique the city view |
| **Dec 24** | **Filmed demo on the king tide**; post written up |
| After Dec 24 (last) | Scheduled refresh on the Pi; WeatherNext rain added beside NWS, once its real-time terms are read and allow it |

**Kill criteria:**
- If geospatial anchoring can't hold ±0.3 ft at the seawall by Dec 12, the AR app becomes a "see the line" viewer that uses a measured seawall marker instead of absolute height, and we say so.
- If the WeatherNext terms block public display, the city view publishes the derived trigger only, or stays on NWS.

## Decided (Oct 26)

- **iOS builds and installs:** the existing MacInCloud Mac, with TestFlight on the existing developer team.
- **Forecast source:** NOAA first (CO-OPS + NWS). WeatherNext and the scheduled refresh are the last task.
- **Repo name:** `craigm26/waterline` (renamed from `waterline-argon-hackathon`; GitHub redirects the old URL).
- **Hosting:** craigmerry.com/waterline/, listed under experiments. GitHub Pages is off.

## Open questions

- Does the WeatherNext grant cover a service account? Only matters if the scheduled job ever moves off the Pi.
- Create the App Store Connect record for Waterline before Nov 14, so the Nov 25 field build can go out on TestFlight.
