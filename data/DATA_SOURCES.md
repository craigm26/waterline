# Data sources

Provenance class: **O** = official, **D** = derived from official inputs, **A** = assumed / estimated.

| Layer | Source | Access | Class |
|---|---|---|---|
| Ensemble forecast rainfall | Google **WeatherNext** | Earth Engine / Google Cloud; request access (may require approval) | O |
| Fallback QPF | NOAA NBM / HRRR / GFS ensemble | Public (NOMADS, AWS Open Data) | O |
| Atmospheric river outlook | CW3E (Scripps) AR forecasts | cw3e.ucsd.edu, public products | O |
| Flood check | Google **Flood Hub** (riverine, plus urban flash flood since Mar 2026) | Website; API by partner application only, so don't depend on it | O |
| Historical flood events | Google **Groundsource** dataset (being open-sourced per Google) | Check release status | O |
| Precipitation frequency | NOAA **Atlas 14** PFDS | `scripts/stage_data.py` (point query) | O |
| Tides / datums | NOAA CO-OPS station **9414290** (San Francisco) | CO-OPS Data API + Metadata API (`stage_data.py`) | O |
| King-tide dates | CO-OPS high/low predictions, Nov 2026 – Feb 2027 | `stage_data.py` | O |
| Terrain | USGS **3DEP 1 m DEM** | TNM Access API (`stage_data.py` lists tiles) | O |
| 3D context | Google **Photorealistic 3D Tiles** | Maps Platform API key | O |
| AR anchoring | **ARCore Geospatial API** (VPS + Streetscape Geometry) | Google Cloud project with ARCore API enabled | O |
| Sewer / inlets | SFPUC / DataSF (SF is mostly a **combined sewer**) | Search DataSF; may not be public at pipe level | O or **A** |
| Flood validation map | SFPUC 100-Year Storm Flood Risk Map | sfpuc.org | O |
| Observed rainfall (replay) | NWS / CNRFC hourly gauges, SF downtown | Public | O |
| Documented flooding (replay truth) | SF 311 cases, news photos | DataSF 311 dataset | O (qualitative) |
| Infiltration / imperviousness | NLCD impervious surface (Earth Engine) | Public | D |

## Demo site constants

- 17th & Folsom, SF: approx. **37.7634, -122.4150** (confirm on the ground)
- Tide station: **9414290**, San Francisco (Golden Gate)
- Bounding box for staging (approx. 1.2 km around the site): `-122.4220,37.7580,-122.4080,37.7690`
