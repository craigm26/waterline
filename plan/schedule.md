# Schedule

Updated Wed Oct 21. The Gemma Hardware Hackathon is **Sat Oct 24** (AGI House, Hillsborough), so treat Oct 24 as lost. **Hard deadline for prep: Fri Oct 23.**

## Prep

| # | Task | By | Status |
|---|---|---|---|
| P1 | **WeatherNext access.** It's now WeatherNext 3; Google says approval typically takes **5–7 business days**. If the form wasn't sent on Oct 17, it **won't arrive in time**: plan on NOAA (NBM/GFS) and say "WeatherNext slots in here" | Today | [ ] Sent? date: ____ |
| P2 | Argon access: paid Gemini API tier or AI Ultra. Confirm whether the event provides credits | Today | [ ] |
| P2b | Run `scripts/smoke_test_argon.py` (one Argon call + one managed-agent call). Note the latency | **Today** | [ ] |
| P3 | Find the event rules (check the event page / ask the organizers): can an AR prototype or MCP server be pre-built? Default assumption: **no**, only data + specs | Thu Oct 22 | [ ] |
| P4 | `python scripts/stage_data.py --download-dem` on the laptop you'll bring (all 12 steps verified Oct 21) | Thu Oct 22 | [ ] |
| P5 | ~~Pick the replay storm~~ **Done:** Dec 31, 2022 (5.46 in downtown; 17 311 flooding reports within 600 m; 17th & Folsom is inside the SFPUC 100-yr zone) | — | [x] |
| P6 | ~~Observed rainfall~~ **Done:** daily GHCN-D + SFO hourly shape staged | — | [x] |
| P7 | ~~Validation layer~~ **Done:** SFPUC 100-yr zone + Dec 2024 flood elevations staged (SFCD → NAVD88 +11.35 ft) | — | [x] |
| P7b | Pick and commit the 10 R2 dry-control points (`plan/verification-harness.md`) | Thu Oct 22 | [ ] |
| P8 | Decide AR approach: native iOS ARCore Geospatial vs 3D Tiles on the laptop (see `plan/argon-prompts.md` §3). Create the Google Cloud project + enable the ARCore API and Maps (3D Tiles) keys | Thu Oct 22 | [ ] |
| P9 | **Film 17th & Folsom B-roll** (shots M1–M4 in `plan/demo-film-plan.md`) | Thu Oct 22 | [ ] |
| P10 | Test a tunnel (cloudflared/ngrok) for the MCP server from home | Fri Oct 23 | [ ] |
| P11 | Rehearse the pitch twice, timed (with placeholder numbers) | Fri Oct 23 | [ ] |
| P12 | Pack (gear list in `plan/demo-film-plan.md`); charge everything | Fri Oct 23 | [ ] |

## Day of: Sun Oct 25, SHACK15 (1 Ferry Plaza), 9:00 AM – 10:00 PM

| Time | Block | Done when |
|---|---|---|
| 8:30 | Arrive early. Re-run `stage_data.py --only kelvin_anomaly flood_levels`; update the pitch numbers. Walk the seawall for 5 min and pick the filming spot | Numbers updated |
| 9:00–9:45 | Check-in, talks. Confirm the **submission deadline, judging format and video rules** | Known |
| 9:45–10:00 | Argon pre-flight prompt (`argon-prompts.md` §0) | Questions answered |
| 10:00–10:45 | MCP server (tunnel); kick off **hydraulics + verifier** (§1) as a background run | Run started |
| **10:45–11:20** | **Step outside: film F0 (real high water, 11:07 AM, ~7.2 ft vs 7.04 flood threshold)** while Argon works | Footage + gauge screenshot |
| 11:20–12:00 | Review the verifier loop; have Argon refresh slide 2 with this morning's gauge data | Baseline verify score logged |
| 12:00–1:30 | Managed-agent fleet wired to MCP; coastal stack; first full replay cycle. **Checkpoint 1:30: end-to-end replay works?** If not, drop live agents and run the pipeline locally, keeping the MCP trace | Replay depth grid + score ≥ target |
| 1:30–3:30 | Trace view + city-manager dashboard (§2) | Both tabs screenshot-clean |
| 3:30–4:30 | AR scene (§3) **or** the 3D Tiles fallback. **Checkpoint 4:30: is AR anchoring?** If not, go to the fallback | Something filmable |
| **4:30–6:00** | **Film outside** (F1–F6); low tide 5:34 PM gives the real-water vs Christmas-Eve contrast. Sunset 6:19 PM | Raw footage on the laptop |
| 6:00–7:00 | Edit the 2-min video (CapCut/iMovie). Run one cached + one live agent cycle | Video exported |
| 7:00–7:30 | Freeze features. Fill `pitch/submission-template.md`. Submit | Submitted |
| 7:30–8:30 | Rehearse 3×; reflection prompt (§4) | |
| 8:30+ | Judging | |

**Cut order if behind:** live forecast (stay on replay) → native AR (use 3D Tiles fallback) → Spanish alert → coordinator disagreement flags. **Never cut:** provenance hatching, the replay vs 311 proof, the Kelvin-wave gauge slide, the outdoor footage.
