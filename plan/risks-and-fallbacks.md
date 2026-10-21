# Risks and fallbacks

| Risk | Likelihood | Fallback |
|---|---|---|
| WeatherNext access not approved in time (5–7 business days, per Google) | **High** | NOAA NBM/GFS ensemble through the same `get_forecast_rain` interface; the `source` field says which. Say "WeatherNext slots in here." |
| AR VPS won't localize, or the native AR build isn't ready by 4:30 | High | 3D Tiles fly-to with the water plane on the laptop, filmed outside. Decide at the 4:30 checkpoint, not later |
| Sunset (≈ 6:15 PM) before the build is filmable | Medium | Film whatever works at 5:30 regardless; stills + 3D view after dark |
| Wind / noise on the Embarcadero ruins audio | High | Wired/lav mic; narrate over the video live on stage anyway |
| Managed agents in Google's remote sandbox can't reach the MCP server (venue Wi-Fi, tunnel blocked) | Medium | Bundle staged data as agent input files; keep the MCP trace from a run that worked; local pipeline for the live demo |
| Argon latency (several minutes per hard run) | **High** | Cache every run; demo from cache; start one live run as the pitch begins |
| Managed Agents is a preview (`antigravity-preview-09-2026`) | Medium | Check the name in the smoke test; own scheduler + JSON state |
| No storm in the forecast on Oct 25 | High | Replay + coastal king-tide scenarios are the demo anyway |
| Overclaiming coastal flooding (realistic case is ~2 ft below the promenade) | Medium | Show the gap honestly; overtopping is hatched; the stress test is labeled |
| Kelvin-wave attribution challenged ("how do you know it's the Kelvin wave?") | Medium | "The gauge residual is measured. The attribution is the scientists' (NC State, NASA JPL), and we label it derived." |
| 311 data bias (presence-only, busy streets) | Medium | Say it; the blind SFPUC check is the second leg |
| SFPUC flood elevations sparse near 17th & Folsom (no elevation polygon at the corner in the Oct 21 check) | Medium | R4 uses only overlapping zones; R3 (zone extent) carries more weight |
| Exhausted after the Gemma hackathon on Oct 24 | High | All prep done by Fri Oct 23; arrive 8:30 with numbers ready |
| Rules forbid pre-built code | Unknown | Only data, specs and prompts are pre-built; all app code is written on the day |
