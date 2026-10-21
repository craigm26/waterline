# Argon prompts (paste on the day)

Following Google's guide: align on intent first, give a verification target, run a pre-flight check, then let it run.

## 0. Pre-flight (thinking_level: medium)

```
You are building Waterline, a screening-level street flood visualizer. Before writing code:
1. Read plan/architecture.md, plan/compound-risk.md, plan/verification-harness.md, plan/mcp-tools.md.
2. List the data files in data/raw/ you will use and confirm each one loads.
3. Ask me up to 5 clarifying questions about edge cases or success criteria.
4. Confirm you can run Python with numpy, rasterio (or GDAL), shapely, pyproj.
Do not write code yet.
```

## 1. Hydraulics module + verifier (thinking_level: high, background=True, max_output_tokens: 262144)

```
Build waterline/hydraulics.py and verify.py.

Goal: for a site bbox and a rainfall scenario, produce a depth grid (P10/P50/P90 across ensemble
members) with a fill-and-spill screening model on the 1 m DEM:
- fill sinks, record spill elevation + storage per sink, route overflow downstream in topological order
- runoff = (rain - infiltration) x contributing area - drain_capacity x duration, clipped at 0
- coastal mode: boundary water level from get_coastal_stack; flood only cells hydraulically connected
  to open water
- every output value carries provenance; assumed inputs make outputs assumed

verify.py implements plan/verification-harness.md exactly (R1, R2, R3, R4, C1, C2, P1, the weighted
score, the target). Keep R3/R4 inputs hidden from the calibration loop: you may read the scores but
not the SFPUC polygons.

Loop: record a baseline score, then change one thing at a time and re-run verify.py, logging each
iteration to runs/verify_log.jsonl, until score >= 0.75 and C1, C2, P1 pass. Parameter bounds:
infiltration 0-15 mm/h, drain capacity 10-60 mm/h. Stop and report if you can't reach the target in
10 iterations; don't loosen the checks.
```

## 2. Trace view + city-manager dashboard (thinking_level: medium)

```
Build a single-page web app (Three.js) with two tabs. 3D scene: load the USGS lidar point cloud
data/lidar/{site}_scene.bin (14-byte stride: float32 x,y,z m local UTM10N, uint8 class, uint8 intensity;
header in the .json) as THREE.Points colored by class; water plane at (W_ft_MLLW - 0.06)/3.28084 m.
Optionally add Google Photorealistic 3D Tiles if a Maps key is set.
- TRACE: left = live agent/MCP log from runs/mcp_log.jsonl with provenance chips (solid = official,
  outlined = derived, hatched = assumed); right = 3D site with the water surface rising as each agent
  finishes. Replay mode shows the 311 report points and the verify score.
- CITY MANAGER: hotspot ranking, P10/P50/P90 timeline vs coastal thresholds (NWS minor 7.04, NOS minor
  7.71, moderate 8.64, major 9.91 ft MLLW), disagreement flags, and a drafted ops brief + public alert
  in English and Spanish.
Always visible: a Limitations panel (screening model, not HEC-RAS; waves/overtopping not modeled;
coupling flags not quantified) and a "REPLAY" / "STRESS TEST" banner when applicable.
Verify by taking browser screenshots of both tabs and fixing layout issues until both render cleanly.
```

## 3. AR scene (thinking_level: medium)

```
Build an iOS (Swift, ARCore Geospatial via CocoaPods 'ARCore/Geospatial') screen that:
- checks VPS availability, localizes, and places a TERRAIN anchor at a surveyed point P; renders the
  water plane at offset Δ = (W_ft_MLLW - 0.06) - G_P_ft_NAVD88 relative to that anchor (see
  plan/ar-anchoring.md); do NOT rely on absolute altitude
- shows the P10-P90 band, a label "X.X ft below promenade" at the coastal site, and toggles
  tide / +El Niño baseline / +storm / stress test
- enables ARKit sceneReconstruction (.mesh) on the iPhone's LiDAR and uses it for occlusion of the water
  plane (ARCore's GARSession is fed frames from our own ARSession)
- hatches any region whose provenance is assumed, with a tap-to-explain card
- screen-records cleanly (no debug overlays)
```

> Before the event: decide whether AR is a native iOS app (best tracking) or WebXR (faster, weaker on iOS). Hard assessment: **native iOS** if you've built ARKit/ARCore before; otherwise do the AR as a **3D Tiles fly-to with the water plane on the laptop** and film that outside. A broken AR app costs more than a clean 3D view.

## 4. Reflection (end of day)

```
Review this session: where did we stall, and why? Write the lessons into AGENTS.md so the next run
of this pipeline (another neighborhood) takes the direct path.
```
