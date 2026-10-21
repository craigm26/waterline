# Compound risk: why this winter is different

Flooding here isn't one hazard. It's several things stacking on the same day. Waterline models the stack explicitly, and **each layer has its own source and provenance class**.

All numbers below come from NOAA CO-OPS station 9414290 (San Francisco), pulled Oct 21, 2026 with `scripts/stage_data.py`. Re-run the script before the event; the October numbers will change.

## Coastal water-level stack (Ferry Building / Embarcadero)

| Layer | What it is | Value now | Source / class |
|---|---|---|---|
| 1. Astronomical tide | Predicted tide; the Christmas-week king tide is the peak | **7.23 ft MLLW**, Dec 24 2026 10:37 (also Jan 21 2027: 7.11; Nov 25: 7.03) | CO-OPS predictions, **O** |
| 2. **Kelvin wave / El Niño baseline** | Coastally trapped ocean waves from the equatorial Pacific raise sea level along the whole coast for months, plus warm-water expansion | Observed minus predicted: **+0.98 ft mean in Oct 1–21, 2026** (max +1.57) vs **+0.26 ft in Oct 2025**. That's about +0.7 ft (8–9 in) of El Niño signal, already here | CO-OPS observed vs predicted, **O** (attribution to Kelvin waves: **D**) |
| 3. Storm surge + wind setup | Low pressure and onshore wind during an atmospheric-river storm | Historical El Niño winters: max residual +2.71 ft (Jan 1983), +1.57 (Dec 1997), **+3.07 (Feb 1998)** | CO-OPS history, **O**; used as scenarios, **A** |
| 4. Wave runup / overtopping | Waves on top of still water splash over the seawall | Not modeled; flagged on screen | **A**: qualitative only |
| 5. Long-term sea-level rise | Already folded into layer 2 (predictions use the 1983–2001 epoch) | Included | Note in the Limitations panel |

**Thresholds at the SF gauge (ft MLLW; converted from station datum, MLLW = 5.98 ft STND):** NWS minor **7.04** · NOS minor **7.71** · NOS moderate **8.64** · NOS major **9.91**. MHHW is 5.84.

**Already happening:** on **Oct 11, 2026** the gauge peaked at **7.57 ft MLLW**, above the NWS minor coastal-flood threshold, in October, before king-tide season. The Embarcadero also flooded during the June 2026 king tides.

### Scenario table (still water at the gauge)

| Scenario | Stack | Water level (ft MLLW) | Category |
|---|---|---|---|
| King tide alone | 7.23 | 7.23 | Above NWS minor |
| + El Niño baseline (today's mean residual) | 7.23 + 0.98 | **8.21** | Above NOS minor |
| + typical big-storm residual | 7.23 + 2.0 | **9.23** | NOS moderate |
| Stress test: Feb-1998 peak residual at the king-tide peak | 7.23 + 3.07 | **10.30** | Above NOS major |

**Ground truth at the venue (USGS 1 m, ft NAVD88; NAVD88 zero is ≈ −0.06 ft MLLW here, so ≈ ft MLLW):** Ferry Building front plaza **10.1**, Ferry Plaza bayside 10.9, Embarcadero at Pier 1 10.5, Embarcadero at Mission St 10.7, Embarcadero at Market 11.3, Harry Bridges Plaza 12.1.

**Hard read:** in the stress test, still water reaches the front-plaza grade outside SHACK15. In the realistic El Niño king-tide case (8.2 ft) it sits about **2 ft below the promenade**, and flooding there comes from **wave overtopping and drains backing up**, not still water. The AR demo must show this honestly: a water line on the seawall face, the gap to the promenade in feet, and a hatched "overtopping likely" band. Don't show the plaza underwater in the realistic case.

> The stress-test row is not a forecast. Feb-1998's peak residual landing exactly on the Christmas king-tide peak is a worst-case coincidence, and the UI labels it "stress test."

## Rain stack (17th & Folsom)

| Layer | Value | Source / class |
|---|---|---|
| Design rainfall | Atlas 14 24-hr: 2-yr **2.27 in**, 100-yr **5.55 in** | **O** |
| Replay storm | Dec 31, 2022: **5.46 in** at SF Downtown, close to a 100-yr 24-hr depth | GHCN-D USW00023272, **O** |
| Hourly shape | SFO ASOS hourly, scaled to the downtown total | **D** (different gauge) |
| Antecedent wetness | Dec 2022 was already wet; El Niño winters stack storms back-to-back | Qualitative flag; **A** |
| Combined-sewer capacity | Folsom-area capacity project: Phase 1 done 2025; tunnel and box sewers run **through 2030**. SFPUC says the area "will still be at risk of flooding during heavy rains" after completion | SFPUC project page, **O**; pipe capacity **A** |
| Ground elevation | 17th & Folsom **21.0 ft** NAVD88, 14th & Folsom 17.9, Folsom & 18th 23.6 | USGS 3DEP, **O** |

**What happened on Dec 31, 2022:** **17** "Sewer Issues / Flooding" 311 reports within 600 m of 17th & Folsom (Folsom, Harrison, Treat, Shotwell, 14th, 15th, 18th, 19th), out of **614 citywide**, between Dec 30 and Jan 1. KQED photographed the flooded 14th & Folsom intersection that day.

**Pitch fact:** the city's fix for this neighborhood isn't finished until 2030. This El Niño arrives first.

## How the hazards link (show these as flags, don't model them)

- **Tide-locked outfalls:** San Francisco's combined sewer drains to the Bay. High Bay water during a king tide plus Kelvin-wave baseline reduces how fast storm water can leave. 17th & Folsom sits at 21 ft, so the tide won't flood it directly, but a storm on a king-tide morning may drain worse. Show this as a flag, "coastal-inland coupling possible", with **A** provenance. Don't quantify it.
- **Back-to-back atmospheric rivers:** El Niño winters bring storm sequences. The coordinator should raise severity when soils and the sewer system are still loaded from the previous storm.
- **More Kelvin waves coming:** NC State's Dillon Amaya expects several more through fall and winter, with sea levels possibly elevated into spring 2027. The baseline layer should update every cycle from the live gauge residual.
- **Out of scope but name them in Limitations:** coastal erosion (Ocean Beach / Great Highway), landslides and debris flows on burn scars, groundwater rise, power outages.

## What the agents do with this

- A new **Coastal agent** builds layers 1–3 from CO-OPS each cycle and hands the water level to the hydraulics agent at the coastal site.
- The **Coordinator** compares the stack with the thresholds and writes the city-manager alert, e.g. "Dec 24 10:37: NOS minor likely (8.2 ft), moderate if a storm arrives (9.2 ft). Pre-stage Embarcadero closure crews 08:30–12:30."
