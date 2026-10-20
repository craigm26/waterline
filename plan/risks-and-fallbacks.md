# Risks and fallbacks

| Risk | Likelihood | Fallback |
|---|---|---|
| AR VPS won't localize indoors at the venue | **Very high** | Pre-recorded on-site footage from Oct 21. Say "recorded this morning/this week." |
| WeatherNext access isn't approved in time | Medium | Use NOAA NBM/HRRR QPF or a public GFS ensemble. Say "WeatherNext slots in here" and keep the interface identical. |
| No storm in the forecast on Oct 25 | High (late Oct) | Replay mode, clearly labeled. The replay-vs-reality comparison is the stronger demo anyway. |
| SF sewer data unavailable | High | Estimate capacity from design standards; hatched. Turn the gap into a demo point. |
| Tide toggle has no effect at 17th & Folsom (inland) | High | Demo the tide toggle at Islais Creek or Mission Creek. 17th & Folsom is the rain story. |
| Exhausted after the Gemma hackathon on Oct 24 | High | All prep done by Oct 22; the day-of plan front-loads the critical path. |
| Argon latency: hard runs take *several minutes* (per Google's guide) | **High** | Cache every agent run; the demo plays from cache. Start one live run as the pitch begins and reveal it at the end only if it finished. Use a 20 min HTTP timeout. |
| Managed Agents is a preview (`antigravity-preview-09-2026`) and may not persist or schedule | Medium | Drive cycles from our own scheduler; keep state in our own JSON. Ask DeepMind staff on the day. |
| Prebuilt-code rules | Unknown | Read the rules (P3). Stage data only; write the code on the day. |
| Over-claiming accuracy in front of domain experts | Medium | Use the Limitations panel and the judge Q&A script. Never say "predicts"; say "screens." |
