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

**Where:** `site/` in this repo, deployed by `.github/workflows/pages.yml` to `https://craigm26.github.io/waterline-argon-hackathon/city/`. The story page in `demo/` stays at the root as the narrative version.

**What the city manager sees first:** the next 15 days of rain and tide for San Francisco on one strip, with WeatherNext p50/p90 rain against the predicted tide plus today's measured anomaly. Then the worst low spots for that forecast on a 3D map. Their first question is "do I need to do anything this week?", and the first screen answers it.

**Panels, in priority order:**
1. **Forecast strip:** WeatherNext 3 hourly `total_precipitation_1hr_{p50,p90}` for the 0.1° cells over SF, plus CO-OPS predicted tide + live residual, with NOAA thresholds drawn as lines.
2. **3D map:** citywide drains (top 500), 50 street low spots, 26k past 311 flooding reports, and a lidar drill-down per hotspot. The existing Act 7 code is the starting point.
3. **Storm Desk:** the 72-hour playbook (`citywide.storm_desk`). It starts as a replay, then becomes a live run triggered when the forecast crosses a threshold.
4. **Briefing export:** the drafted brief and alerts (EN/ES/ZH) as text the manager can copy. Approval stays with a person: the page never sends anything.

**Data refresh:** a scheduled job runs `scripts/refresh_live.py` (to write), which pulls CO-OPS and WeatherNext, writes `site/data/forecast.json`, and commits so Pages redeploys. It can run either as a GitHub Action on a cron schedule with a GCP service-account secret, or as cron on the Pi. **I'd start on the Pi**, because the WeatherNext grant is tied to my Google account and gcloud on the Pi is the shortest path to a first working query. Move it to Actions once a service account can read the linked dataset.

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
- **Device install:** a Mac with Xcode (free provisioning lasts 7 days per install), or TestFlight, which needs the Apple Developer Program ($99/yr). For testing at the seawall, the Mac route is enough.
- **Field validation is the real test:** on Nov 25 we film the phone next to a tape-measure reading against a fixed seawall mark at the tide-gauge time. Then the AR line has to sit within ±0.2 ft of the real water. If it's off, we fix the anchor math before Dec 24.

## Milestones

| By | Done when |
|---|---|
| Oct 31 | Pages live with the story site; WeatherNext query returns SF rain p50/p90 from the Pi; licensing terms read and decided |
| Nov 7 | `site/` city view MVP: forecast strip + 3D map + hotspot drill-down, nightly refresh from the Pi |
| Nov 14 | iOS project in `ios/` building in CI; geospatial anchor + water plane on a device at home (test plane at a known height) |
| **Nov 25** | **Field test 1 at the Ferry Building**; Storm Desk replay in the city view |
| Dec 12 | Storm Desk live run against a real forecast; alerts drafted; render loop (`render_watch.py`) used to critique the city view |
| **Dec 24** | **Filmed demo on the king tide**; post written up |

**Kill criteria:**
- If geospatial anchoring can't hold ±0.3 ft at the seawall by Dec 12, the AR app becomes a "see the line" viewer that uses a measured seawall marker instead of absolute height, and we say so.
- If the WeatherNext terms block public display, the city view publishes the derived trigger only.

## Open questions

- Which Mac (or Xcode Cloud) builds and installs the iOS app? Is there an Apple Developer account?
- Does the WeatherNext grant cover a service account in my GCP project, or only my user account? This decides Pi cron vs GitHub Actions.
- Should the repo be renamed from `waterline-argon-hackathon` to `waterline`? GitHub redirects the old URL, but the Pages URL changes with the name, so the QR code and links would need updating.
