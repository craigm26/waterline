# Alert and brief copy (templates)

`{braces}` are filled by the coordinator agent from the depth grid and coastal stack. Every message carries the prototype disclaimer. Waterline is a hackathon prototype and must never look like an official city alert.

**Disclaimer, always appended**
- EN: *Waterline prototype, screening estimate only, not an official alert. For official warnings, follow AlertSF and the National Weather Service.*
- ES: *Prototipo Waterline: estimación preliminar, no es una alerta oficial. Para avisos oficiales, siga AlertSF y el Servicio Meteorológico Nacional.*

---

## Resident: push / SMS (≤ 160 chars before the disclaimer)

**Coastal (king tide + El Niño)**
- EN: `High water near {place}, {day} {start}–{end}. Expect water {gap_ft} ft below the promenade; waves may splash over. Avoid the seawall edge.`
- ES: `Marea alta cerca de {place}, {day} {start}–{end}. El agua llegará a {gap_ft} pies del paseo; las olas pueden saltar. Aléjese del borde del malecón.`

**Rain (street ponding)**
- EN: `Street flooding likely at {place}, {day} {start}–{end}: about {depth_in} in of water. Move cars off low streets; clear the drain by your door if safe.`
- ES: `Probable inundación en {place}, {day} {start}–{end}: unos {depth_in} pulgadas de agua. Saque su auto de calles bajas; limpie el desagüe frente a su puerta si es seguro.`

## Resident: in-app card (3 actions)

| EN | ES |
|---|---|
| **{depth_band}** at your block, **{day} {start}–{end}** | **{depth_band}** en su cuadra, **{day} {start}–{end}** |
| 1. Move your car to higher ground before {start}. | 1. Mueva su auto a un lugar más alto antes de las {start}. |
| 2. If it's safe, clear leaves from the storm drain nearest your door. | 2. Si es seguro, quite las hojas del desagüe más cercano a su puerta. |
| 3. Ground floor or basement? Put sandbags or a barrier at the door, and know your backflow valve. | 3. ¿Primer piso o sótano? Ponga sacos de arena o una barrera en la puerta y ubique su válvula antirretorno. |
| *Hatched areas are estimates: tap to see why.* | *Las zonas rayadas son estimaciones: toque para ver por qué.* |

## City manager: ops brief (auto-drafted)

```
WATERLINE SITUATION BRIEF · cycle {cycle_id} · issued {issued_local}
Sources this cycle: forecast={forecast_source}; tide=NOAA CO-OPS 9414290; terrain=USGS 3DEP 1 m

HEADLINE
{site}: {category} likely {day} {start}–{end}. Still water {level_ft} ft MLLW (P50; P10–P90 {p10}–{p90}).
Kelvin-wave / El Niño baseline this cycle: {baseline_ft:+.2f} ft above prediction (measured).

THRESHOLD TIMELINE (SF gauge, ft MLLW)
  NWS minor 7.04 · NOS minor 7.71 · NOS moderate 8.64 · NOS major 9.91
  {timeline_rows}

HOTSPOTS (ranked)
  {rank}. {block}: {depth_band}, {start}–{end}, provenance {official|derived|assumed}

RECOMMENDED ACTIONS (for human decision)
  - Pre-stage crews at {hotspot_1} by {stage_time}
  - Sandbag distribution: {sandbag_site} open {open_time}
  - Consider lane closures: {segment} {start}–{end}
  - Public message: resident template "{template_id}" (EN/ES attached)

DISAGREEMENT
  {models_disagree_text or "Ensemble members agree within ±{spread} in."}

LIMITATIONS
  Screening model, not HEC-RAS. Wave overtopping and tide-locked outfalls flagged, not modeled.
  Sewer capacity is assumed (hatched) where pipe data is unavailable.
```

> The coordinator **recommends**; a person **decides**. The brief never sends a public alert by itself (same doctrine as Bellwether).
