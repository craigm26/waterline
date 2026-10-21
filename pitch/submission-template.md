# Submission template (fill in at ~7:00 PM)

**Project:** Waterline

**One-liner:** Street-level flood screening for this winter's strong El Niño, with a resident AR view and a city-manager dashboard, run by Gemini 4 Argon managed agents.

**Problem:** NOAA expects a strong-to-very-strong El Niño, and a Kelvin wave already has the San Francisco tide gauge running about a foot above prediction (it crossed the NWS minor flood threshold on Oct 11). Forecasts stop at the county; people and crews act at the block.

**What we built (today):**
- Gemini Managed Agents (`gemini-4-argon` on the Antigravity harness), one per site, re-run each forecast cycle: forecast, coastal stack (tide + Kelvin-wave baseline + surge), terrain, drainage, hydraulics, coordinator
- An MCP data server where every value carries provenance (official / derived / assumed)
- Argon-written fill-and-spill hydraulics, calibrated against a verification harness: Dec 31, 2022 replay vs 17 SF 311 flooding reports, plus a blind check against the SFPUC 100-year flood map. Score [baseline] → [final]
- Resident AR view (ARCore Geospatial), filmed outside the venue on the Embarcadero
- City-manager dashboard: threshold timeline vs NOAA flood levels, hotspot ranking, drafted ops brief + EN/ES public alert

**Google tech:** Gemini 4 Argon, Gemini Managed Agents, [Gemini 3.8 Flash subagents], [WeatherNext | NOAA fallback], ARCore Geospatial API, Photorealistic 3D Tiles, [Flood Hub as reference]

**Data:** NOAA CO-OPS 9414290, NOAA Atlas 14, GHCN-D, USGS 3DEP 1 m, SFPUC 100-Year Storm Flood Risk Map, SF 311 (DataSF)

**Limitations:** Screening model, not HEC-RAS/MIKE. Wave overtopping and tide-locked outfalls are flagged, not modeled. 311 data is presence-only.

**Video:** [link]  **Repo:** [public link or "private, available on request"]
