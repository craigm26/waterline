# MCP data server: tool contracts

Managed agents call MCP tools natively (Argon guide). This server is the only way agents touch data, so provenance is enforced in one place. **Write the code on the day; this file is the spec.**

Every tool returns an envelope:

```json
{
  "data": { ... },
  "provenance": "official | derived | assumed",
  "source": "human-readable source + id",
  "retrieved_at": "ISO-8601",
  "notes": "required when provenance != official"
}
```

| Tool | Args | Returns | Provenance |
|---|---|---|---|
| `get_site` | `site: "rain" \| "coast"` | name, lat/lon, bbox, spot elevations | official |
| `get_dem` | `site`, `resolution_m=1` | path to a clipped GeoTIFF + stats (min/max/mean) | official |
| `get_design_storm` | `site`, `ari_years`, `duration` | depth (in), from Atlas 14 | official |
| `get_forecast_rain` | `site`, `hours=72` | ensemble members `[ {member, hourly_mm[]} ]` | official (WeatherNext if available, else NOAA NBM/GFS; `source` says which) |
| `get_replay_rain` | `storm_id="2022-12-31"` | hourly series scaled to the downtown daily total | **derived** (SFO shape × downtown total) |
| `get_tide` | `start`, `end` | predicted series + observed residual stats + thresholds in ft MLLW | official (thresholds converted: **derived**) |
| `get_coastal_stack` | `datetime`, `scenario: tide\|baseline\|storm\|stress` | water level ft MLLW + each layer | per-layer, see `compound-risk.md` |
| `get_drain_capacity` | `site` | `capacity_mm_per_hr` per sub-catchment | **assumed** unless pipe data is found |
| `get_ground_truth` | `storm_id`, `site` | 311 points (+ type), SFPUC zones | official |
| `write_depth_grid` | `site`, `scenario`, `grid`, `p10/p50/p90` | path, checksum | derived / assumed (inherits from inputs) |
| `write_situation_report` | `markdown`, `alerts[]` | path | derived |
| `run_verify` | `site`, `scenario` | score breakdown (see `verification-harness.md`) | derived |

## Implementation notes

- Python `mcp` SDK, stdio or streamable HTTP. Managed agents run in Google's **remote** sandbox (`environment="remote"`), so the server must be **reachable from the internet**. Plan: run it on the laptop behind a tunnel (`cloudflared tunnel` or ngrok). Test the tunnel at the venue in the morning; venue Wi-Fi can block it. **Fallback:** bundle the staged data into the agent's input files and skip MCP for the live demo, keeping the MCP trace from earlier runs.
- Read from `data/raw/` only. No live network calls during the demo except the forecast and tide refresh.
- Log every call (tool, args, latency, provenance) to `runs/mcp_log.jsonl`. The trace view reads this file.
