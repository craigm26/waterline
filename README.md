# Waterline

**Now (Oct 26):** we're past the hackathon and building v2 in the open: a city-manager view on the web and an AR app for iOS, both field-tested on the Nov 25 and Dec 24 king tides, with WeatherNext 3 as the forecast. Plan: [`plan/v2-roadmap.md`](plan/v2-roadmap.md). Live site: https://craigm26.github.io/waterline-argon-hackathon/. Everything below is the original hackathon prep, kept because the data and analysis carry over.

---

## Hackathon prep package

**Event:** Gemini 4 Argon hackathon, Google DeepMind · **SHACK15, 1 Ferry Plaza (Ferry Building), San Francisco**
**When:** Sun Oct 25, 2026, 9:00 AM – 10:00 PM PDT
**Prizes:** $7.5K / $5K / $2.5K, plus **$5K Best use of Managed Agents** (we're targeting a placing prize and the Managed Agents prize)

> Waterline is street-level flood screening for this winter's strong El Niño. A fleet of Gemini 4 Argon managed agents stacks rain, tides, the El Niño **Kelvin-wave** baseline, storm surge, terrain and sewer capacity into a depth for each block. Residents see it as a water line through their phone's camera; city managers get a block-by-block timeline against NOAA's flood thresholds with a drafted alert.

## The numbers that carry the pitch (pulled Oct 21, 2026)

- NOAA: El Niño Advisory; strong-to-very-strong likely through Jan–Mar 2027; 70–83% chance it's the strongest since 1950.
- **SF tide gauge, Oct 1–21, 2026: +0.98 ft above prediction on average** (Oct 2025: +0.26). That's the Kelvin wave, already here. **Oct 11: 7.57 ft MLLW, above the NWS minor flood threshold (7.04).**
- **Christmas Eve king tide: 7.23 ft MLLW** predicted. Plus today's baseline: **8.2 ft** (NOS minor). Plus a big storm: **9.2 ft** (moderate). Ferry Building plaza grade: **≈ 10.1 ft**.
- **Dec 31, 2022 replay:** 5.46 in at SF Downtown (Atlas 14 100-yr 24-hr = 5.55 in); **17 SF 311 flooding reports within 600 m of 17th & Folsom**, 614 citywide; 17th & Folsom is inside the SFPUC 100-year flood zone.
- The SFPUC fix for 17th & Folsom (tunnel + box sewers) runs **through 2030**. This El Niño arrives first.

## Contributing

Run the demo: `cd demo && python -m http.server 8000`. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup and the data contracts, and [`plan/track2-loop.md`](plan/track2-loop.md) for what we're building and who does what.

## What's in here

| Path | What |
|---|---|
| **`plan/track2-loop.md`** | **Our track (Problem Statement Two):** render → watch → critique → fix loop, rubric, critique schema, work split |
| `scripts/render_watch.py` | Renders the 3D scenes to stills + `orbit.mp4` + manifest so Argon can watch them (`renders/iterN/`) |
| `scripts/loop_report.py` | Critiques → score chart + iteration strip (the measured improvement) |
| **`demo/index.html`** | **The story demo**: five acts, live lidar scene, real data, footage slots (`plan/story.md`) |
| `plan/story.md` | Story arc, footage file names, drain walk, what's computed Sunday |
| `scripts/citywide_analysis.py` | Citywide drain ranking + street low spots + validation vs 311 (runs anywhere; ~1 min) |
| `scripts/download_citywide.py` | Resumable citywide downloads (photos, drains, 311, SFPUC, SF 1 m DEM) |
| `scripts/drain_priority.py` | Ranks real SFPUC drains by water reaching each grate (lidar terrain) |
| `scripts/build_story_data.py` | Packs data + assets into `demo/` |
| `pitch/application-answers.md` | Paste-ready application answers |
| `pitch/pitch-2min.md` | 2-min and 60-s stage scripts (resident + city-manager), fallback lines |
| `pitch/judge-qa.md` | Likely judge questions with 10-second answers |
| `pitch/slides-outline.md` | 5 slides + backup |
| `pitch/submission-template.md` | Fill-in-the-blanks submission text |
| `plan/schedule.md` | Prep checklist to Fri Oct 23 + the hour-by-hour day plan with checkpoints |
| `plan/demo-film-plan.md` | **Outdoor recorded demo**: two personas, shot lists (Ferry Building + 17th & Folsom), sunset window, gear |
| `plan/ar-anchoring.md` | Terrain-relative AR water placement, scenario offsets at the Ferry Building, pre-filming checks |
| `scripts/build_assets.py` | Builds charts, terrain clips, ground-truth layers, dry controls, maps, ensemble snapshots |
| `assets/` | Charts, maps, brand kit, EN/ES alert copy, gallery (`assets/index.html`) |
| `plan/lidar.md` | USGS point cloud crops, lidar-vs-DEM checks, Folsom curb profile, iPhone LiDAR occlusion plan |
| `scripts/fetch_lidar.py` | Streams USGS 3DEP point clouds from AWS EPT; Three.js bins, renders, cross-sections |
| `plan/compound-risk.md` | **Kelvin wave + king tide + surge + rain** stack, thresholds, scenario table, coupling flags |
| `plan/architecture.md` | Agent pipeline, data contracts, provenance rules |
| `plan/argon-api-notes.md` | Argon developer-guide facts and the Managed Agents call |
| `plan/mcp-tools.md` | MCP data-server tool contracts |
| `plan/verification-harness.md` | Argon's pass/fail target: 311 replay + blind SFPUC check |
| `plan/argon-prompts.md` | Paste-ready prompts for the day |
| `plan/risks-and-fallbacks.md` | What breaks, and what we do when it does |
| `data/DATA_SOURCES.md` | Every source: endpoint, access, provenance class, findings |
| `scripts/stage_data.py` | Stages all data for both sites (12 steps; all verified live Oct 21) |
| `scripts/smoke_test_argon.py` | Pre-event check: one Argon call + one managed-agent call |

## Demo sites

| Site | Hazard | Role in the demo |
|---|---|---|
| **Ferry Building / Embarcadero** (outside the venue) | Coastal: king tide + Kelvin-wave baseline + storm surge | Resident AR cut, **filmed on the day** |
| **17th & Folsom, Mission** | Rain + combined-sewer capacity (ground at 21 ft, so not tidal) | Replay proof (Dec 31, 2022 vs 311) and city-manager cut |

## Status

- [x] Concept, pitch, application answers, two-persona demo plan
- [x] All data staged and verified (tides, thresholds, Kelvin anomaly, Atlas 14, rainfall, 311, SFPUC, DEM index)
- [x] Replay storm chosen and verified: Dec 31, 2022
- [x] Demo assets built from live data (Oct 21): 4 charts, 2 maps, terrain clips, ground truth, 10 pre-registered dry controls, GEFS/ECMWF ensemble snapshots, EN/ES alert copy, brand kit. Gallery: `assets/index.html`
- [x] Lidar (Oct 21): USGS 2023 point clouds for both sites (Three.js-ready), lidar agrees with the DEM within 0.3 ft at 4 checkpoints, Folsom curb/crown profile
- [ ] WeatherNext request sent (if not already, assume NOAA fallback)
- [ ] `scripts/smoke_test_argon.py` passes
- [ ] Event rules checked (pre-built code?)
- [ ] 17th & Folsom B-roll filmed
- [ ] Pitch rehearsed

## Ground rules

1. Every number on screen links to its source. **Solid** = official, **outlined** = derived, **hatched** = assumed.
2. Screening model, not HEC-RAS, and the app says so on screen.
3. No generated flood imagery; the water surface comes only from the computed depth grid.
4. A stress test is labeled as a stress test. The realistic case is shown even when it's less dramatic.
