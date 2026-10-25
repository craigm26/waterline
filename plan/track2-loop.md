# Track 2 · More Dimensions: render → watch → critique → fix

**Decision (Oct 24 evening): we enter Problem Statement Two.** The submission is the web city-manager 3D view, built by Argon and improved by a loop where Argon watches its own render and compares it to reality. The iPhone AR app becomes optional B-roll and is not something we build.

> Track 2 text: *"A single pass is only the first draft. Build a system that renders what it made, watches the result, critiques it against the goal, and fixes it in a loop."*

## The pitch in one line

Argon builds a 3D flood view of San Francisco from city lidar in one pass, then watches its own render next to the real flood (311 photos from New Year's Eve 2022 and video we shot of this morning's high water outside the venue). It writes down what's wrong and fixes it. The score climbs on screen, iteration by iteration.

Other teams can say their render looks better. Waterline can say its render **matches the water on the street**. That's the difference to land with judges.

## The loop

```
          ┌───────────────────────── goal + rubric (below) ─────────────────────────┐
          ▼                                                                          │
 [1] GENERATE   Argon, one long decode: city-manager 3D view (Three.js) from        │
                demo/story-data.json + the depth grid + drain status                │
          ▼                                                                          │
 [2] RENDER     scripts/render_watch.py → renders/iterN/ (stills, orbit.mp4,        │
                contact sheet, manifest with on-screen numbers, page errors)         │
          ▼                                                                          │
 [3] WATCH      Argon watches orbit.mp4 + stills, next to the REFERENCE SET:         │
                 • 8 NYE-2022 citizen photos (known location, Gemini depth reading)   │
                 • F0: this morning's real high water at the seawall (video)          │
                 • lidar truth numbers (plaza grade, curb heights, bowl floor)        │
          ▼                                                                          │
 [4] CRITIQUE   JSON: score per rubric item, each defect with frame + evidence +     │
                the fix (schema below)                                               │
          ▼                                                                          │
 [5] FIX        Argon patches the page (and the model inputs if physics is wrong) ───┘
                stop when score ≥ 0.85 or after 5 iterations; keep every iteration
```

The physics loop already in the plan (hydraulics agent vs 311 + SFPUC, `plan/verification-harness.md`) runs inside step 5. When the critique says "the water here is 2 ft too deep vs the photo," the fix goes to the model, not just the shader.

## Rubric (the "goal" Argon critiques against)

Weights sum to 1. **Physical honesty counts for half**; that's the half other teams don't have.

| id | Weight | Check | How Argon checks it |
|---|---|---|---|
| P1 | 0.15 | Water only where it can get to: Bay-connected (coast) or inside a mapped bowl (rain). No floating sheets, no water on hills | Watch the orbit; flag any water surface not contiguous with the Bay or bowl |
| P2 | 0.15 | Depth at the 8 photo points within ±0.5 ft of the photo reading | `results.json.photo_depths` vs the on-screen readout for each point |
| P3 | 0.10 | Curbs, steps and plaza edges read correctly against water (the curb shows when the depth is under curb height) | Stills at 1 ft / 4 ft vs the lidar curb profile (`data/derived/lidar_checks.json`) |
| P4 | 0.10 | Ferry Building scenarios match this morning: at the measured tide, the render shows what F0 shows (dry plaza, water at the seawall face) | F0 frames vs `ferry_s*` at the matching level |
| L1 | 0.10 | A city manager can tell in 5 seconds where the worst spots are and what to do | Watch the first 5 s of orbit.mp4 cold; say what you'd do. Pass if it matches the top 3 hotspots |
| L2 | 0.10 | Provenance visible: official solid, derived outlined, assumed hatched; stress test labeled | Look for an unlabeled assumed value in any frame |
| L3 | 0.10 | Labels readable, nothing overlapping, legend present, numbers have units | Stills at 1280×800 and phone width |
| V1 | 0.10 | Looks good: lighting, depth cue, water reads as water, camera frames the bowl | Judge it like a juror would |
| R1 | 0.10 | No page errors; every scene loads in < 5 s | `manifest.json.page_errors`, timings |

## Critique schema (`renders/iterN/critique.json`)

```json
{
  "iteration": 1,
  "score": 0.71,
  "items": {"P1": 0.8, "P2": 0.5, "P3": 0.9, "P4": 0.7, "L1": 0.6, "L2": 1.0, "L3": 0.7, "V1": 0.6, "R1": 1.0},
  "defects": [
    {"id": "d1", "rubric": "P2", "severity": "high",
     "frame": "hs_rank2_4ft.png", "where": "17th & Folsom, NE corner",
     "evidence": "Photo 3 (Dec 31 2022, 18:42) reads ~1.0 ft at the curb; render shows 2.6 ft",
     "cause": "bowl seeded on the BART stairwell pit (5.6 m)",
     "fix": "exclude pits deeper than 2 m from the bowl seed; re-run fill", "target": "model"},
    {"id": "d2", "rubric": "L1", "severity": "med", "frame": "orbit.mp4@00:03",
     "evidence": "first view is the whole city; no hotspot is called out",
     "fix": "open on hotspot #2 with a label and the drain count", "target": "page"}
  ],
  "keep": ["Bay-connected fill on the Ferry scene reads right; don't touch it"]
}
```

`keep` matters: it stops the loop from breaking what already works. Each fix is checked by the next render.

## What we show (the measured improvement)

- **Iteration strip** on the page: the same frame for iter0 → iterN, with the score under each, and one defect caption per step ("water on a hill → removed", "2.6 ft → 1.1 ft vs photo").
- **Score chart:** rubric score and the 311 verification score per iteration. Baseline = Argon's single pass (iter0).
- **Side by side in the video:** F0 real high water | iter0 render | final render, all at the same tide.
- Every claim comes from `renders/*/critique.json`. No numbers until the loop has run.

## Work split

| | Craig | Superwoman |
|---|---|---|
| Before 9 AM | Data is staged. Bring the repo, film F0 at 11:07 AM | Read `demo/index.html` + this file; pick the 3D look |
| Build | Argon/agents: generation prompt, `render_watch.py`, critique + fix loop, managed agents, hydraulics verifier, results.json | **City-manager 3D view** (Three.js), integrating sim outputs (depth grid, drain status), making agent activity readable (Storm Desk + loop trace), iteration strip |
| Interface | Produces `demo/story-data.json`, `demo/results.json`, `renders/iterN/{manifest,critique}.json` | Consumes those; owns how they look |
| Video | Outdoor footage F0 (morning) + seawall B-roll (4:30–6 PM); narration | **Directs, scripts, edits** the submission video |
| Pitch | Delivers | Shapes the story beats with the video |

**Rule:** the page reads only the JSON contracts. Then Argon can regenerate the page without breaking the data, and the data can change without breaking the page.

## Day-of changes to `plan/schedule.md`

- 10:00 Start the loop on iter0 instead of the AR scene. **Checkpoint 1:30:** at least 2 iterations rendered and critiqued.
- 3:30–4:30 slot (was AR): run loop iterations 3–5 and build the iteration strip.
- Cut order: AR first (now optional), then the live forecast. **Never cut:** the loop trace and the F0-vs-render comparison.

## Rules caveat

If code must be written on the day, `render_watch.py` and the current page are the reference spec; Argon regenerates both in the first long decode. That's fine for Track 2: iter0 *is* Argon's single pass.
