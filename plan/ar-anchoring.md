# AR anchoring: getting the water at the right height

The water line is only credible if it sits at the right height. Absolute altitude from GPS or VPS is the weak link, so **anchor relative to the ground.**

## Recommended: terrain-relative placement

1. Create an ARCore **Terrain anchor** (Geospatial API) at a surveyed point P on the promenade or street. ARCore places it on its own ground surface at P.
2. Look up the ground elevation at P from our 1 m DEM: `G_P` (ft NAVD88).
3. Water plane offset from the anchor: **`Δ = (W − 0.06) − G_P`**, where `W` is the scenario water level in ft MLLW (NAVD88 zero = −0.06 ft MLLW at SF). Negative = below the promenade.
4. Render the plane at `Δ` relative to the anchor, extending bayward (coast) or along the street (rain).

This cancels datum and geoid errors, because both ARCore's terrain and our DEM describe the same ground. What remains is DEM-vs-ARCore terrain disagreement at P (check by eye: the anchor should sit on the pavement).

## Numbers at the Ferry Building (from staged data)

| Scenario | W (ft MLLW) | G_P front plaza (ft NAVD88) | Δ (ft) | Δ (m) |
|---|---|---|---|---|
| King tide alone | 7.23 | 10.1 | −2.93 | −0.89 |
| + El Niño baseline | 8.21 | 10.1 | −1.95 | −0.59 |
| + big storm | 9.23 | 10.1 | −0.93 | −0.28 |
| Stress test | 10.30 | 10.1 | +0.14 | +0.04 |

(`data/derived/coastal_stack.json` holds the exact values; regenerate the morning of the event.)

**Filming-time contrast (Sun Oct 25):** predicted low tide **−0.34 ft MLLW at 5:34 PM**. Plus about 1 ft of residual, the real Bay surface is roughly 0.6–0.7 ft MLLW, about **9.5 ft below the plaza**. The Christmas Eve "+ El Niño" plane sits about **7.5 ft above the real water in the shot**. Say it on camera.

## If you must use absolute altitude

- Geospatial anchors take WGS84 ellipsoid height. **GEOID18 N = −32.49 m** (Ferry Building) and **−32.54 m** (17th & Folsom), per the NGS Geoid API. Ellipsoid h ≈ NAVD88 H + N.
- NAD83(2011) vs WGS84 adds roughly 1 m of horizontal and vertical difference, and VPS altitude accuracy is about a meter at best. **That error is larger than the gap between scenarios.** Don't use absolute altitude for the money shot.

## Checks before filming (on the day, ~4:15 PM)

- [ ] `checkVPSAvailabilityAtCoordinate` at 37.7953, −122.3940 returns available
- [ ] The terrain anchor visually sits on the pavement at P (no float, no sink)
- [ ] A tape-measured step (curb or seawall cap) matches the DEM delta within ~10 cm
- [ ] The plane is stable while walking 10 m along the seawall
