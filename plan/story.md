# The story demo (`demo/`)

**Goal:** a flashy, mostly pre-recorded web demo with one strong story. The page in `demo/index.html` *is* the demo. On stage, scroll it top to bottom. Every act already runs on real data, and empty slots fill in as footage and Sunday's computed numbers land.

## The arc: prediction → proof → prevention

| Act | Headline | What's on screen | Pre-recorded / computed |
|---|---|---|---|
| Hero | "On October 11, San Francisco Bay crossed flood stage." | 7.57 ft, animated waterline | Data (live gauge) |
| 1 · It's already here | The Kelvin wave is in the tide gauge | 2026 vs 2025 gauge chart, stat tiles, **footage F0** (real high water outside SHACK15, 11:07 AM Sunday) | Chart: data. F0: filmed Sunday morning |
| 2 · The resident | Christmas Eve, 10:37 AM, at the Ferry Building | **Live 3D lidar scene** (661k points); scenario buttons raise water that can only spread from the Bay; resident alert EN/ES; **footage F2–F4** (AR on the seawall) | Scene: live. F2–F4: filmed Sunday 4:30–6 PM |
| 3 · The proof | New Year's Eve 2022 | 311 + SFPUC ground-truth map, replay rain, **Argon verification score baseline → final** | Score: computed Sunday |
| 4 · The city | Block-by-block timeline, drafted before crews are called | Agent pipeline, Christmas-week tide timeline vs NOAA thresholds, **auto-drafted brief** (windows computed from data) | Live from data |
| 5 · Before the storm | Twelve drains matter most; a robot finds out which are blocked | Real SFPUC drain map, top-12 ranked, **footage R1** (rover scout), scout cards → Gemini verdicts | R1: pre-recorded. Verdicts: Sunday |
| Close | Strong El Niño. Street level. This winter. | | |

## Added Oct 22

- **Hero:** live SF tide-gauge reading (NOAA allows cross-site requests, so it works when you run the site locally; falls back to the latest staged daily value on the published page).
- **Act 1:** Kelvin-wave timeline: measured, expected and predicted events through spring 2027 (`data/derived/kelvin_outlook.json`).
- **Act 3:** the 8 citizen photos from Dec 31, 2022 (plates blurred, street-level places), each with a Gemini depth-reading chip and a model-depth chip filled from `results.json`.
- **Act 5:** payoff stat (from `results.json`), the 1.6× citywide validation, and footage slot **A1** (adopt and clear drain N-339755).
- **Act 6 · The whole city:** citywide map (top 500 drains, top 50 street low spots, 26k 311 reports), tap-anywhere "any block" panel with presets, footage slot **V1** (any-block agent time-lapse), and a lidar drill-down for 5 hotspots with a fill slider.
- **Close:** QR code to the published page. **Set the page's sharing to "anyone with the link" before Sunday, or judges' phones can't open it.**

## Sunday fills (`demo/results.json`)

Copy `demo/results.example.json` → `demo/results.json` and fill from real runs: `verify`, `photo_depths`, `model_at_photos`, `scout`, `payoff`, `any_block_run`. Each block appears on the page only when its key exists. Prompts: `plan/argon-prompts.md` §5–7.

## Footage to drop in

Put MP4s in `demo/media/` with these exact names; the page detects them and plays them in place of the placeholder.

| File | Shot | When |
|---|---|---|
| `media/f0_high_water.mp4` | Real high water at the Embarcadero seawall + gauge screenshot | **Sun 10:45–11:20 AM** |
| `media/f2_resident_ar.mp4` | AR water line on the seawall, scenario toggles | **Sun 4:30–6:00 PM** (sunset 6:19) |
| `media/a1_adopt_clear.mp4` | Adopt drain N-339755 and clear it | Thu Oct 22 |
| `media/v1_any_block.mp4` | Agents building an unprepared block (time-lapse) | Sun |
| `media/r1_rover_scout.mp4` | Rover drives to a leaf-covered grate; Gemini label appears | **Fri at home, or Sat at the Gemma hackathon** with the rover already set up there |

Keep each clip 10–25 s, landscape 16:9, no audio needed (you narrate live). Compress with `ffmpeg -i in.mov -vf scale=1280:-2 -c:v libx264 -crf 26 -an out.mp4`.

## Shots added for the robot act

| # | Shot | When | Notes |
|---|---|---|---|
| **D1–D12** | **Drain walk:** photograph each of the 12 priority grates (straight down, plus one wide) | **Today, Thu Oct 22**, with the 17th & Folsom B-roll | List with map links in `data/derived/drain_walk.md`. Name files `D{rank}.jpg`. On Sunday Gemini classifies each as clear / partly blocked / blocked. Those labels fill the scout cards. |
| R1 | Rover approaches a grate covered with real leaves (staged at home on a grate or a printed grate photo), stops, photographs; the overlay shows Gemini's label | Fri / Sat | Use gemma-plantree's rover + depth camera. Keep it obviously a demo rig, not a public-street deployment. |

## What gets computed on Sunday (so the demo isn't hollow)

1. **Verification score**, baseline → final (Act 3): from `verify.py` against the 311 + SFPUC ground truth.
2. **Scout verdicts** (Act 5): Gemini vision on D1–D12 photos.
3. **Prevention payoff** (Act 5, step 4): re-run hydraulics with the blocked priority drains cleared vs blocked → "ponding avoided" at 17th & Folsom. **Don't put a number there until it's computed.**
4. Agent trace from a real managed-agent cycle (Act 4 can link to it).

## Running it

- Rebuild data: `python scripts/build_story_data.py` (copies images, the lidar, and a base64 twin into `demo/`).
- Local: `cd demo && python -m http.server 8000` → http://localhost:8000 (needs http, not file://).
- Stage: full-screen browser, zoom to fit, scroll act by act. The lidar scene auto-orbits; click a scenario to raise the water.

## Rules caveat

This site was built before the event. If the rules require all code to be written on the day, treat it as the **design reference**: on Sunday, have Argon rebuild the site from `demo/index.html` + `plan/story.md` as the spec (one long-decode run), and present that version.
