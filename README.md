# Waterline: prep package

**Event:** Gemini 4 Argon hackathon, Google DeepMind, San Francisco
**When:** Sun Oct 25, 2026, 9:00 AM – 10:00 PM PDT
**Prizes:** $7.5K / $5K / $2.5K, plus **$5K Best use of Managed Agents** (we're targeting both a placing prize and the Managed Agents prize)

> NOAA (Oct 8, 2026): El Niño Advisory, with a strong-to-very-strong event likely through Jan–Mar 2027. NOAA puts the chance that it beats every El Niño since 1950 at 70–83%.
> Waterline is a fleet of Gemini 4 Argon managed agents. It turns Google WeatherNext forecasts, tides and 1 m lidar into flood depths for a single city block, and shows them as a water line on your street through your phone's camera.

## What's in here

| Path | What |
|---|---|
| `pitch/application-answers.md` | Paste-ready application answers (2-sentence pitch, demo plan, proudest project) |
| `pitch/pitch-2min.md` | 2-minute stage script, 60-second cut, fallback lines |
| `pitch/judge-qa.md` | Likely judge questions with 10-second answers |
| `plan/architecture.md` | Agent pipeline, data contracts, provenance rules |
| `plan/schedule.md` | Prep checklist for Oct 17–24, plus an hour-by-hour plan for Oct 25 |
| `plan/risks-and-fallbacks.md` | What breaks, and what we do when it does |
| `data/DATA_SOURCES.md` | Every data source: endpoint, access steps, provenance class |
| `scripts/stage_data.py` | Pre-stages tide, Atlas 14 and lidar-index data for the demo site |

## Demo site

**17th & Folsom, Mission District, SF** (approx. 37.7634, -122.4150; confirm on the ground). This is a well-known flooding hotspot in a combined-sewer area. Backup sites for the sea-level-rise angle are Islais Creek and Mission Creek.

## Status

- [x] Concept, pitch and application answers
- [ ] Data access requests sent (WeatherNext / Earth Engine, Argon keys)
- [ ] Data staged locally (`scripts/stage_data.py`)
- [ ] Replay storm chosen and verified (see `plan/schedule.md`)
- [ ] On-site AR footage recorded at 17th & Folsom (backup video)

## Ground rules for ourselves

1. Every number on screen links to its source. Official data is drawn **solid**; anything interpolated or assumed is **hatched**.
2. This is a screening model, not HEC-RAS, and the app says so on screen.
3. No generated imagery of flooding that isn't constrained by the computed depth grid.
