# Stage pitch

About 300 words. **[Brackets]** are actions; quoted text is what you say. The demo segment plays the **recorded outdoor video** (`plan/demo-film-plan.md`). Narrate over it live; don't let the video's audio carry the pitch.

**Morning-of:** re-run `python scripts/stage_data.py --only kelvin_anomaly flood_levels` and update the **[bracketed numbers]**.

## 2-minute version

**0:00–0:15 — Hook** *[Slide: SF tide gauge, observed vs predicted, October 2026]*
"This is San Francisco's tide gauge, a few miles up the shoreline at the Golden Gate. All October it's run **[nearly a foot]** above prediction. That's the Kelvin wave from this El Niño, which NOAA says could be the strongest since 1950. On October 11 it crossed the flood threshold, and king-tide season hasn't started."

**0:15–0:30 — Problem**
"Forecasts tell a county it's getting three inches of rain or a high tide. They don't tell a resident whether water reaches their door, or a city manager which block to send crews to and when. People act at street level."

**0:30–1:00 — Resident** *[Video: walking out of the Ferry Building, AR on the seawall]*
"This is Waterline, filmed right outside this building this afternoon. Christmas Eve king tide: here. Add today's El Niño baseline: here, about two feet below the promenade. Add a 1998-size storm and it's at the edge." *[Tap hatch]* "Hatched means estimated: wave overtopping isn't modeled, and the app says so."

**1:00–1:30 — City manager** *[Trace view + dashboard]*
"Same scenario, city side. A fleet of Gemini managed agents, one per site, re-runs every forecast cycle: rain, tides, terrain, sewer capacity, all through one MCP server where every number carries its source. The coordinator turns it into a timeline against NOAA's flood thresholds and drafts the ops brief and the public alert, in English and Spanish."

**1:30–1:50 — Proof** *[Replay: 17th & Folsom, model vs 311 dots]*
"Inland, in the Mission, we replayed New Year's Eve 2022, 5.46 inches. We didn't tell Argon how to model the flood. We gave it that storm and the 17 flooding reports from that night, and it rewrote its model until it agreed. Score went from **[0.4x]** to **[0.7x]**. The city's tunnel for this neighborhood isn't finished until 2030. This El Niño arrives first."

**1:50–2:00 — Close**
"A Kelvin wave already raising the Bay, a strong El Niño behind it, and a street-level answer for both the people who live there and the people who respond. That's Waterline."

---

## 60-second version

"The San Francisco tide gauge has run nearly a foot above prediction all October. That's this El Niño's Kelvin wave, and it already crossed the flood threshold on October 11. *[Video]* This is Waterline, filmed outside this building: the Christmas Eve king tide plus today's El Niño baseline, two feet below the promenade, hatched where we're estimating. *[Dashboard]* For the city: Gemini managed agents turn rain, tides, terrain and sewer capacity into a block-by-block timeline against NOAA's thresholds and draft the alert. *[Replay]* We proved it on New Year's Eve 2022: Argon rewrote its model until it matched 17 real flooding reports. Strong El Niño, street level, this winter. That's Waterline."

---

## Fallback lines

- **Video won't play:** "Here's the same scenario in 3D," then fly the trace view to the Ferry Building.
- **Live agent run didn't finish:** "This is the run from 4 PM; agents take minutes per cycle, and we cache every one."
- **Asked about the 2-ft gap ("so it won't flood?"):** "Still water stays below the promenade in the realistic case. Waves on top of it are what flooded the Embarcadero in June. That's why it's hatched, not hidden."

## Optional opener (if F0 shows the Bay at flood stage at 11 AM)
"At 11 this morning, right outside this building, San Francisco Bay hit flood stage. It's October." Then go straight into the gauge slide.

## Fill in on the day

- [ ] Morning residual ("nearly a foot" = Oct mean +0.98 ft as of Oct 21)
- [ ] Verify score baseline → final
- [ ] Argon line count / tokens (if you mention them)
