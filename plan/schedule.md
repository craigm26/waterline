# Schedule

## Prep: Oct 17–24

The Gemma Hardware Hackathon is **Oct 24** (Hillsborough). Assume Oct 24 is lost, so everything below must be done by **Thu Oct 22**.

| # | Task | By | Done |
|---|---|---|---|
| P1 | Request WeatherNext access (Earth Engine / Google Cloud). Access may need approval. | Sat Oct 17 | [ ] |
| P2 | Confirm Argon API keys or credits are provided at the event; otherwise check access on your own account | Sat Oct 17 | [ ] |
| P3 | Read the event rules: what may be built in advance (data staging is usually fine; code usually isn't) | Sun Oct 18 | [ ] |
| P4 | Run `scripts/stage_data.py` (tides, Atlas 14, lidar index) and download the DEM tiles | Sun Oct 18 | [ ] |
| P5 | **Pick the replay storm.** Candidates: Dec 31, 2022 (record SF rain, widely reported flooding) and Dec 11, 2014. Confirm *documented flooding at 17th & Folsom* (311, news photos, SFPUC). | Mon Oct 19 | [ ] |
| P6 | Pull hourly observed rainfall for the replay storm (SF downtown gauge) | Mon Oct 19 | [ ] |
| P7 | Find SF sewer/inlet data, or the SFPUC 100-year storm flood risk map, as a validation layer | Tue Oct 20 | [ ] |
| P8 | ARCore Geospatial: get a hello-world anchor working on your phone (API key, VPS coverage at the site) | Tue Oct 20 | [ ] |
| P9 | **Go to 17th & Folsom**, test VPS localization, and record backup AR footage (needs P8) | Wed Oct 21 | [ ] |
| P10 | Rehearse the 2-minute pitch out loud twice, timed | Thu Oct 22 | [ ] |
| P2b | Make one test `gemini-4-argon` call and one Managed Agents call with your own key (see `plan/argon-api-notes.md` checklist) | Tue Oct 20 | [ ] |
| P7b | Sketch the MCP tool list and its JSON schemas (the code gets written on the day) | Thu Oct 22 | [ ] |
| P11 | Pack: phone + cable/adapter for screen mirroring, charger, backup video on laptop *and* phone | Thu Oct 22 | [ ] |

## Day of: Sun Oct 25 (9:00 AM – 10:00 PM)

| Time | Block |
|---|---|
| 9:00–9:45 | Check-in, talks, confirm submission deadline and judging format |
| 9:45–11:30 | **Argon one-shot:** generate the hydraulics module and trace view from `plan/architecture.md`. Get one depth grid end-to-end in replay mode |
| 11:30–1:30 | Stand up managed agents (forecast → terrain → drainage → hydraulics → coordinator) on the replay storm |
| 1:30–2:00 | Lunch; **checkpoint: is the end-to-end replay working?** If not, cut AR and polish the trace view |
| 2:00–4:30 | Wire the live forecast (WeatherNext if access arrived; otherwise any public QPF) and the provenance hatching |
| 4:30–6:30 | AR: load the depth grid into the geospatial anchor scene; use the backup video if VPS won't work indoors |
| 6:30–7:30 | Freeze features. Record the demo video. Write the README and submission |
| 7:30–8:30 | Rehearse the pitch 3×; fill in the real numbers |
| 8:30+ | Judging |

**Cut order if behind:** live forecast (stay on replay) → AR (use video) → the coordinator's disagreement flags. **Never cut:** the provenance hatching and the replay-vs-reality comparison. Those are what make it credible.
