# Data sources

Provenance class: **O** = official, **D** = derived from official inputs, **A** = assumed / estimated.

| Layer | Source | Access | Class |
|---|---|---|---|
| Ensemble forecast rainfall | Google **WeatherNext 3** (64-member ensemble on GCS; mean/percentile stats on Earth Engine and BigQuery) | [Data Request Form](https://docs.google.com/forms/d/e/1FAIpQLSeCf1JY8G78UDWzbm0ly9kJxfSjUIJT5WyMR_HiNqCm-IHIBg/viewform); **5–7 business days**; no paid contract needed. Real-time data under GDM experimental terms; historical (≥ 1 h old) is CC BY 4.0 | O |
| Fallback QPF | NOAA NBM / GFS ensemble (GEFS) | Public (NOMADS, AWS Open Data) | O |
| Atmospheric river outlook | CW3E (Scripps) AR forecasts | cw3e.ucsd.edu | O |
| Flood check | Google **Flood Hub** | Website; API by partner application only | O |
| Precipitation frequency | NOAA **Atlas 14** PFDS | `stage_data.py atlas14` | O |
| Tides, datums, **flood thresholds** | NOAA CO-OPS **9414290** | `stage_data.py tide_datums flood_levels king_tides` | O (thresholds converted to MLLW: D) |
| **Kelvin-wave / El Niño baseline** | CO-OPS observed minus predicted | `stage_data.py kelvin_anomaly` | O (measurement), D (attribution) |
| Daily rainfall (replay) | GHCN-Daily **USW00023272** SF Downtown | NCEI Access Data Service | O |
| Hourly rainfall shape (replay) | IEM ASOS **SFO** p01i | mesonet.agron.iastate.edu | D (different gauge; scaled) |
| Replay ground truth | SF 311 `vw6y-z8j6`, service_subtype = **Flooding** | DataSF SODA API | O (presence-only) |
| Official 100-yr flood extent | SFPUC 100-Year Storm Flood Risk Zone (July 2022) `jzu3-4yxp` | data.sf.gov GeoJSON | O |
| Official 100-yr flood elevations | SFPUC Flood Elevations (Dec 2024) `wppz-u2hi`, fields `contourmin/contourmax`, **SF City Datum** | data.sf.gov GeoJSON | O |
| Terrain | USGS **3DEP 1 m DEM** CA_SanFrancisco_B23 | TNM Access API | O |
| **Lidar point cloud** | USGS 3DEP **CA_SanFrancisco_1_B23** (2023) via AWS EPT, 13.1 B points, Z m NAVD88; buildings unclassified (class 1) | `scripts/fetch_lidar.py` (streams only intersecting octree nodes) | O |
| Spot elevations | USGS EPQS | epqs.nationalmap.gov | O |
| 3D context | Google **Photorealistic 3D Tiles** | Maps Platform key | O |
| AR anchoring | **ARCore Geospatial** (iOS: CocoaPods `ARCore/Geospatial ~> 1.56.0`; keyless auth preferred; check VPS with `checkVPSAvailabilityAtCoordinate`; ~5 m / 5° typical accuracy) | Google Cloud project | O |
| Sewer capacity | SFPUC pipe data not found public | Design-standard estimate | **A** |
| Imperviousness | NLCD (Earth Engine) | Public | D |

## Datum conversions (critical; get these wrong and the water is in the wrong place)

- Station datum: **MLLW = 5.98 ft STND**, MHHW = 11.82 STND → **MHHW = 5.84 ft MLLW**.
- **NAVD88 zero = −0.06 ft MLLW** at SF, so DEM elevations (NAVD88) ≈ ft MLLW (add 0.06).
- **SF City Datum: NAVD88 = SFCD + 11.35 ft** (City & County Surveyor constant; local benchmarks vary 10.9–11.8).
- CO-OPS flood levels come in STND: subtract 5.98 to get MLLW.
- AR anchors use WGS84 ellipsoid height: NAVD88 → ellipsoid needs the GEOID18 offset (about −32 m around SF; compute exactly on the day).

## Findings (staging run Oct 21, 2026; all 12 steps OK)

- **Thresholds (ft MLLW):** NWS minor 7.04 · NOS minor 7.71 · NOS moderate 8.64 · NOS major 9.91.
- **Observed − predicted:** Oct 1–21 2026 **+0.98** mean (max 1.57) · Sep 2026 +0.57 · Oct 2025 +0.26 · Jan 1983 +0.64 (max 2.71) · Dec 1997 +0.53 (1.57) · Jan 1998 +0.63 (1.41) · Feb 1998 **+1.01 (3.07)** · Dec 2022 +0.24 (1.20).
- **Oct 11, 2026 observed peak 7.57 ft MLLW** (above NWS minor).
- **King tides:** Dec 24 10:37 **7.23**; Dec 23 7.19; Jan 21 7.11; Jan 22 7.09; Dec 25 7.08; Nov 25 7.03.
- **Atlas 14 at 17th & Folsom (in):** 24-hr 2-yr 2.27, 10-yr 3.46, 25-yr 4.24, 100-yr 5.55; 1-hr 100-yr 1.29.
- **Replay:** SF Downtown Dec 30 0.81, **Dec 31 5.46**, Jan 1 0.00. SFO hourly total 3.68 in, peak 0.55 in at 13:56.
- **311 Flooding, Dec 30 – Jan 1:** 17 within 600 m of 17th & Folsom; 4 near the Ferry Building; 614 citywide.
- **SFPUC check:** 17th & Folsom, 14th & Folsom and Folsom & 18th are **inside** the 100-yr zone; Ferry Building plaza is not (expected: the layer is storm runoff only, not Bay flooding). Elevation polygons are sparse near the corner (Folsom & 18th: 11–12 ft SFCD).
- **Ground (ft NAVD88):** Ferry Bldg plaza 10.1 · Ferry Plaza bayside 10.9 · Embarcadero at Pier 1 10.5 · at Mission 10.7 · at Market 11.3 · Harry Bridges Plaza 12.1 · 17th & Folsom 21.0 · 14th & Folsom 17.9 · Folsom & 18th 23.6.

## Demo site constants

- 17th & Folsom: **37.7634, -122.4150**; bbox `-122.4220,37.7580,-122.4080,37.7690`
- Ferry Building / Embarcadero: **37.7955, -122.3935**; bbox `-122.3990,37.7905,-122.3880,37.8000`
- Tide station **9414290** (San Francisco)
