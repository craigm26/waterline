# Outdoor recorded demo

**Why this works:** SHACK15 is at **1 Ferry Plaza**, inside the Ferry Building. The Embarcadero seawall, one of SF's best-known king-tide flooding spots, is about 50 m from the door. You can film the coastal AR demo **during the event**, with the app built that day, so the footage is unambiguously hackathon work.

## Two users, two cuts

| | **Resident cut** ("Will my street flood?") | **City-manager cut** ("Where do I send crews, and when?") |
|---|---|---|
| Device | Phone, AR | Laptop, Watch Desk (trace view + map) |
| Question | Is water coming to *my* block, how deep, when, what should I do? | Which blocks and assets cross a threshold, when, how confident, what action? |
| Output | Water line in the camera, depth band, time window, 3 plain-language actions | Ranked hotspot list, P10/P50/P90 timeline, threshold crossings, auto-drafted ops brief and public alert (EN/ES) |
| Honesty | Hatched = estimated; "screening, not a guarantee" | Provenance chip on every number; disagreement flag; Limitations panel |
| Length in final video | ~45 s | ~45 s |

## Shot list: Ferry Building / Embarcadero (film ON Oct 25)

**Windows on Sun Oct 25:**
- **10:45–11:20 AM, real high water (no app needed):** predicted high **6.23 ft MLLW at 11:07**. Plus the current ~+1 ft Kelvin-wave residual, the real Bay may reach about **7.2 ft**, at or above the **NWS minor flood threshold (7.04)**. Film the actual water at the seawall and screenshot the live CO-OPS reading. If it crosses, that's your opening shot: "This morning, outside this building, the Bay hit flood stage."
- **4:30–6:00 PM, AR:** low tide **−0.34 ft at 5:34 PM**, so the real Bay is about 9.5 ft below the plaza and the Christmas Eve plane floats about 7.5 ft above the real water. Use that contrast. **Sunset 6:19 PM**, civil twilight ends 6:46. Anchoring method and numbers: `plan/ar-anchoring.md`.

| # | Shot | Device | Notes |
|---|---|---|---|
| F0 | **11:00 AM**: real high water at the seawall + phone screenshot of the live CO-OPS 9414290 reading | Phone | Real footage, no app. Strongest proof the threat is now |
| F1 | Wide: you walk out of the Ferry Building toward the Embarcadero seawall | Phone 2 / friend | 5 s establishing shot. Clock tower in frame = instantly "San Francisco" |
| F2 | AR: point at the seawall face, toggle *king tide* → *+ El Niño baseline* → *+ storm* | Phone (screen record) | Water line rises on the seawall; a label shows "2.0 ft below promenade" etc. |
| F3 | AR: toggle *stress test*: water reaches the plaza grade | Phone | Big "STRESS TEST, not a forecast" label stays visible |
| F4 | Tap the hatched band: "overtopping likely, waves not modeled" | Phone | The honesty beat |
| F5 | Talking head, 10 s: "This gauge is already running about 9 inches high because of the Kelvin wave." | Phone 2 | Say the number you get from the morning re-run |
| F7 | 5-s orbit of the lidar Ferry Building scene with the water plane rising (screen capture) | Laptop | The 3D establishing shot if 3D Tiles has no key |
| F6 | Laptop on a bench: city-manager view of the same scenario, alert drafted | Phone 2 filming laptop | Ties the two cuts together |

## Shot list: 17th & Folsom (film BEFORE the event, Wed Oct 21 / Thu Oct 22)

The app won't exist yet, so this is **B-roll only**: real street, real curb, real storm drains. On the day, combine it with the trace view and the replay comparison.

| # | Shot | Notes |
|---|---|---|
| M1 | Wide of the 17th & Folsom intersection, street sign in frame | Establishing |
| M2 | Close-up of a curb inlet / storm drain | For the "drain capacity" voice-over |
| M3 | Slow pan along Folsom toward 14th | Matches the Dec 31, 2022 311 report locations |
| M5 | Tape-measure both Folsom curbs just south of 17th, then iPhone LiDAR-scan the same 3 m of curb (`plan/lidar.md`) | Lidar says ~4 in west / ~9 in east; the measured number goes on the slide |
| M4 | Note the GPS reading on the phone at the corner | Confirms the site coordinates (37.7634, -122.4150) |

If the event rules allow a pre-built AR prototype (check P3), also test **VPS availability** at both sites with `GARSession.checkVPSAvailabilityAtCoordinate`. Otherwise do it at lunch on the day for the Ferry Building only.

## Final video structure (≈ 2:00, for submission and as a stage backup)

1. 0:00–0:10 F1 + title: "Strong El Niño. Kelvin wave already here."
2. 0:10–0:55 **Resident cut** at the Ferry Building: F2 → F3 → F4
3. 0:55–1:40 **City-manager cut**: trace view, threshold timeline, drafted brief; then the 17th & Folsom replay (M1–M3 B-roll + model vs. 311 reports)
4. 1:40–2:00 F5 talking head + close

## Gear

- [ ] iPhone 16 Pro Max (AR) + a second phone for B-roll (or a friend)
- [ ] Battery pack, plus a USB-C to HDMI adapter for stage mirroring
- [ ] Lav or wired mic for F5 (Embarcadero wind is loud)
- [ ] Gimbal or phone holder (the gemma-plantree phone holder works)
- [ ] Laptop with full brightness for F6 (outdoor glare)

## Fallback order

Live AR outside → recorded AR (this plan) → trace view + 3D Tiles with a simulated water plane on the laptop → static before/after stills.
