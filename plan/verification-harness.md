# Verification harness (Argon's pass/fail target)

Google's Argon guide says the model does its best long-horizon work against a concrete pass/fail check. This is ours. Argon writes and rewrites the hydraulics module until `verify.py` passes; we record the baseline score and every iteration (for the pitch).

## Ground truth (staged by `scripts/stage_data.py`)

| Check | Truth source | Pass condition |
|---|---|---|
| **R1. Replay wet points** | 17 SF 311 "Sewer Issues / Flooding" reports within 600 m of 17th & Folsom, Dec 30, 2022 – Jan 1, 2023 (`sf311_flooding_rain_replay.json`). Use the **On_street** reports as the primary set | Predicted P50 depth ≥ 0.05 m within 30 m of ≥ 70% of On_street report locations |
| **R2. Replay dry controls** | 10 points we pick on high ground in the same bbox (e.g. near Folsom & 18th at 23.6 ft); none in 311 | Predicted depth < 0.05 m at ≥ 90% of controls |
| **R3. SFPUC 100-yr zone agreement** | SFPUC 100-Year Storm Flood Risk Zone (deep, contiguous ≥ 6 in flooding) | Under the Atlas 14 100-yr 24-hr storm (5.55 in), IoU with the SFPUC zone inside the bbox ≥ 0.4 (screening model; don't overfit) |
| **R4. SFPUC 100-yr elevations** | SFPUC Flood Elevations (Dec 2024), SF City Datum. **NAVD88 = SFCD + 11.35 ft** | Median absolute water-surface difference inside overlapping zones ≤ 1.0 ft |
| **C1. Coastal stack arithmetic** | CO-OPS predictions + residual + thresholds | Unit test: the scenario table in `compound-risk.md` reproduces to ±0.02 ft |
| **C2. Coastal connectivity** | 1 m DEM | Water at the Ferry Building site only floods cells hydraulically connected to the Bay (no inland "bathtub islands") |
| **P1. Provenance completeness** | All outputs | Every value has a `provenance` field; any depth that depends on an `assumed` input is `assumed` |

## Scoring

```
score = 0.35*R1 + 0.15*R2 + 0.25*R3 + 0.15*R4 + 0.10*(C1 and C2 and P1)
target: score ≥ 0.75 and all of C1, C2, P1 pass
```

Log each iteration to `runs/verify_log.jsonl`: `{iter, score, R1..P1, change_summary, tokens}`. The **baseline → final** line is a pitch moment: "Argon started at 0.41 and got to 0.79 in 6 iterations."

## Overfitting guard

- Keep the **R3/R4 checks blind** for the first iterations: Argon sees the scores, not the SFPUC polygons. Otherwise it will just paint the SFPUC zone.
- Freeze the parameter ranges (infiltration 0–15 mm/h, drain capacity 10–60 mm/h) so Argon can't set physically silly values to win.
- Say this in the Q&A: "We validated against data the model didn't train its parameters on."

## Notes

- 311 reports are qualitative, biased toward busy streets, and geocoded to addresses or intersections. Treat them as presence-only evidence, never depth.
- Pick the R2 dry controls **before** the event (Thu Oct 22) and commit them, so you aren't choosing them after seeing results.
