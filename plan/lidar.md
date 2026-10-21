# Lidar in Waterline

Three lidar sources, each with a different job.

## 1. USGS 3DEP point cloud (2023): staged, in the repo

The `CA_SanFrancisco_1_B23` survey is public on AWS as an Entwine (EPT) octree: **13.1 billion points**, EPSG:3857 horizontal, **Z in metres NAVD88**. `scripts/fetch_lidar.py` streams only the octree nodes inside each crop, so there's no need to download 2+ GB of tiles per site.

| Crop | Points | Depth | Use |
|---|---|---|---|
| `coast_scene` (440 m box, Ferry Building) | 661,599 | 7 | Three.js backdrop, renders |
| `rain_scene` (360 m box, 17th & Folsom) | 348,548 | 7 | Three.js backdrop |
| `rain_xsec` (60 m box) | 246,307 | 12 | Folsom St cross-section (curb / crown / gutter) |
| `coast_edge` (60 m box) | 375,026 | 12 | Seawall edge ground + Bay surface |

`--depth 9` gives about 15M points for a scene, which is too heavy for git and a laptop browser. Use it only for a local hero render.

**Survey quirk:** buildings are left **unclassified (class 1)**, not class 6. Ground is class 2 and water is class 9. Filter on class 2 for any ground measurement.

### What it measured (in `data/derived/lidar_checks.json`)

| Check | Lidar ground (ft NAVD88) | Bare-earth DEM | Δ |
|---|---|---|---|
| Ferry Building front plaza | 10.40 | 10.1 | +0.3 |
| Embarcadero at Market | 11.25 | 11.3 | −0.05 |
| Ferry Plaza bayside | 11.17 | 10.9 | +0.27 |
| 17th & Folsom | 20.87 | 21.0 | −0.13 |
| Seawall edge, median ground | 11.12 | — | — |
| **Bay surface at flight time** | **−0.23** | — | (≈ low tide) |

**Pitch line for "how good is your terrain?":** "Two independent USGS products agree within a third of a foot at every checkpoint."

**Folsom St, just south of 17th:** crown **21.5 ft**, gutters **20.4 / 20.6 ft**, so the street crowns about 1 ft above its gutters over about 17 m. Lidar curb relief is about **4 in (west, blurred by the bike-lane buffer) / 9 in (east)**. Meaning: about **4 inches of water** in the west gutter is the point where it starts reaching the sidewalk. **Tape-measure both curbs on Thursday's B-roll visit** (M5 below) and put the measured number on the slide.

### How the build uses it

- **Three.js backdrop without a Maps key:** load `data/lidar/{site}_scene.bin` (14-byte stride: float32 x,y,z in metres, local UTM 10N origin from the `.json`; uint8 class; uint8 intensity) as a `THREE.Points` cloud. Draw the water plane at `(W_ft_MLLW − 0.06) / 3.28084` metres. That's the trace-view and city-manager 3D scene even if Photorealistic 3D Tiles never get a key, and it's measured geometry rather than photogrammetry.
- **Hydraulics:** the bare-earth DEM stays the model surface. Lidar class 1 points give building footprints if Argon wants to block flow through buildings.
- **Street-level depth meaning:** the coordinator translates depth into curb terms using the measured profile. "4 in: gutters full; above that, water on the sidewalk."
- **Renders:** `assets/lidar/coast_scene.png` (base) and `coast_scene_stress_test.png` (ground at or below 10.3 ft tinted). The realistic scenarios tint no ground at all, which is the honest result, so they aren't rendered.

## 2. iPhone 16 Pro Max LiDAR: on site

The phone's LiDAR scanner (about 5 m range) does two jobs the survey can't:

1. **AR occlusion.** ARCore Geospatial on iOS runs on your own `ARSession`, so you can enable `sceneReconstruction = .mesh` on the `ARWorldTrackingConfiguration` while feeding frames to `GARSession`. Use the mesh for occlusion so the water plane hides behind the seawall railing, bollards and people instead of floating over them. Biggest single realism win in the AR shot.
2. **Ground-truth measurement.** On Thursday, scan the Folsom curb and the seawall cap with any LiDAR scan app (export a mesh or point cloud) and compare against the USGS profile. Film it as B-roll: "we checked the survey against the street."

Fallback if AR tracking struggles: skip occlusion and keep the terrain anchor (see `ar-anchoring.md`).

## 3. Your own lidar tooling

The Bare Earth project (Sacramento County lidar search) and the stadium shade-map work overlap with this pipeline: the same 3DEP sources, ground classification and hillshades. Nothing from them is needed for Sunday. If there's a Bare Earth helper for EPT or PDAL already written, it can replace `fetch_lidar.py` later.

## Shot additions (`demo-film-plan.md`)

| # | Shot | When |
|---|---|---|
| M5 | Tape measure on both Folsom curbs just south of 17th; then an iPhone LiDAR scan of the same 3 m of curb | Thu Oct 22 |
| F7 | 5-second orbit of the lidar Ferry Building scene in the trace view, water plane rising | Sun, from the laptop |
