# Stage pitch

About 300 words at a steady pace. **[Brackets]** are actions; quoted text is what you say.

## 2-minute version

**0:00–0:15 — Hook** *[Title slide: NOAA ENSO plume]*
"Eight days ago NOAA put the odds at seventy percent that this winter's El Niño will be the strongest since record-keeping began in 1950. The last two big ones, 1983 and 1998, put California underwater. This one is already here."

> Adjust "eight days ago" to the actual gap from NOAA's latest ENSO update (the Oct 8 update is 17 days before the event; the November update lands Nov 12). Safer wording: "This month NOAA put the odds..."

**0:15–0:35 — Problem**
"Forecasts today tell you a county is getting three inches of rain. They don't tell you whether there'll be water over your front step at 17th and Folsom on Thursday night. Nobody acts on 'the region.' People act on 'my street.'"

**0:35–1:15 — Demo** *[Phone mirrored to screen, or the on-site video]*
"This is Waterline. I'm pointing my phone down Folsom Street." *[Water plane appears]*
"That's the forecast water surface for the next atmospheric river, placed at the right height against the real buildings. Google's Geospatial API anchors it."
*[Toggle: king tide]* "Add a December king tide and it gets worse here." *[Toggle: storm + tide]* "Here's both at once, which is the scenario El Niño makes likely."
*[Tap a hatched area]* "Hatched means estimated. We didn't have the pipe invert here, so the app says so. Solid means official data."

> Note: 17th & Folsom floods from rainfall and combined-sewer capacity, not tides. If the tide toggle doesn't move the water there, demo the tide toggle at Islais Creek or Mission Creek instead, and say "here's where the tide matters."

**1:15–1:40 — How it works** *[Watch Desk trace view]*
"Behind that is a fleet of managed agents, one per watershed, that never stops running. Each one pulls WeatherNext ensembles, atmospheric-river forecasts, river gauges and tides, and keeps a living situation report. When the forecasts disagree, a coordinator agent flags it. 'The models disagree' is information too."

**1:40–1:55 — What's new this week**
"Argon is what made this possible this week. It wrote the street-scale flood model for this neighborhood in one run, more than [N] thousand lines. Pick any city block in California and we can generate its model the same way."

**1:55–2:00 — Close**
"Strong El Niño, this winter, at street level. That's Waterline."

---

## 60-second version

"NOAA says this winter's El Niño has a seventy percent chance of being the strongest on record. Forecasts stop at the county line; people act at their street. *[Phone]* This is Waterline: the forecast water surface for the next storm at 17th and Folsom, anchored to the real buildings. Hatched means estimated, solid means official. *[Trace view]* Behind it, Gemini 4 Argon managed agents turn WeatherNext rainfall, lidar terrain and sewer capacity into a depth for each block, and flag when the forecasts disagree. *[Replay]* Here's the same pipeline replaying a real past storm, next to what actually flooded. Strong El Niño, this winter, at street level. That's Waterline."

---

## Fallback lines

- **AR won't anchor indoors (expected):** "Recorded at 17th & Folsom this morning." Play the video. Don't fight live AR on stage.
- **No storm in the forecast:** run the Watch Desk in replay mode and keep the "REPLAY" label visible on screen.
- **Argon latency during the demo:** show cached agent runs from earlier in the day, and say they're cached.

## Fill in on the day

- [ ] The real line count Argon produced (or drop the sentence)
- [ ] The next forecast storm date, if there is one
- [ ] The replay storm's name and date
