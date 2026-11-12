# Waterline for iOS

Waterline answers "does it flood here?" for wherever you're standing, with no setup. 1.0 only worked at the Ferry Building after you typed in a mark's height. 1.1 reads the ground under you and checks it against tides, rain and the city's own flood history.

**Here** (from GPS, or any spot you tap on the map):
- **Ground height.** USGS 3DEP via EPQS when online (1 m lidar in SF). Offline, the bundled 5 m SF grid.
- **Where the Bay gets in.** "Bay reaches here at" is the lowest Bay level that gets to this spot overland, from a priority flood over the lidar. A spot below the tide but behind higher ground shows as dry until the water tops the rim.
- **Tides anywhere on a US coast.** The nearest NOAA CO-OPS station (within 60 km): highs for 30 days, the 30-day anomaly, NOAA flood thresholds, and the station's own NAVD88 to MLLW tie.
- **Rain anywhere in the US.** NWS gridpoint rain for the next 24 h and 3 days.
- **SF only:**
  - bowl depth here and nearby
  - SFPUC 100-year zone
  - 311 flooding reports within 500 ft
  - the closest top-500 drains, with deep pits flagged
  - the nearest of the 50 worst low spots
  - higher ground that stays dry in a strong storm on this month's highest tide
- **A plain-language verdict** (low / some / higher risk), the reasons behind it, and what to do.

**Map:** tap anywhere to check it. Drains are colored by citywide rank, past 311 reports show as dots, and the SFPUC zone is outlined.

**Water line (camera):**
- **Ground anchoring, no mark.** ARKit finds the pavement ahead of you, and the water floats at the scenario's depth above it, with a pole and label. Scenarios: the bowl filling with rain, the next high tide, this month's highest, plus the gauge anomaly, plus a strong storm (▨), and a labelled stress test. A level that can't get here overland shows as "doesn't reach this spot".
- **LiDAR.** Scene reconstruction with classification hides the water behind people and objects. *Measure a step:* tap the street, then your doorstep or curb, and the mesh gives the height. The panel then says whether each scenario goes over your step.
- **Barometer.** *Floor height:* start on the street, walk up, save. CMAltimeter measures the climb to about a foot.
- **Compass.** Arrows to higher ground and to the drain that matters, which turn as you turn.

**Anywhere in the US, live:**
- **River gauges** from the NWS National Water Prediction Service within 50 miles: stage, forecast and flood category. For the nearest gauge within 8 km, flood stage becomes an elevation through the gauge's NAVD88 datum, so the app can say "at major stage the river stands 16.5 ft above your ground" (Natomas, from the Sacramento River at I Street). It's limited to 8 km because a river's surface rises upstream.
- **FEMA flood zone** at the spot, from the National Flood Hazard Layer, in plain words (A99, AE with BFE, levee-protected X, ...).
- **Region packs** for Sacramento, New Orleans, Miami, Norfolk, Charleston, Houston, NYC and Boston: 10 m ground + bowl grids from USGS 3DEP (`scripts/build_regions.py`, `regions/regions.json`). Behind a levee the bowl is the basin depth; floodwalls and seawalls thinner than 10 m aren't resolved, and the New Orleans, Miami and Charleston packs say so.

**AR sky view** (Water line tab): tags at their true bearing (ARKit `gravityAndHeading`), at three zoom levels:
- Street, 400 m: drains, the bowl next to you
- Neighborhood, 4 km: low spots, higher ground, lidar scenes
- Watershed, 80 km: upstream river gauges with live stage and flood category, the tide station

Overlapping tags stack, and the most severe keeps its true position. Tap a gauge for NOAA's live hydrograph.

**Offline data** (the ⬇ button on Here): download packs listed in `packs/manifest.json`, served from GitHub release `packs-v1`. Every file is checked against SHA-256 before it's used.

| Pack | Size | What the app does with it |
|---|---|---|
| SF ground, 1 m lidar (low-lying areas) | 45 MB | Ground to the inch offline, for all SF land at or below 30 ft MLLW; takes over from the 5 m grid |
| Lidar point clouds | 26 MB | Ferry Building + 5 hotspots in a 3D viewer with a water slider and "% of ground under" |
| Raw LAZ / GeoTIFF / citywide 1 m tiles | 22 / 19 / 523 MB | Nothing in-app: they're for other apps, via Files › On My iPhone › Waterline |

Rebuild and republish packs on the desktop (it has the 1 m tiles): `python scripts/build_packs.py --dem1m data/raw/citywide/dem`, then `gh release create packs-vN dist/packs/*` and commit `packs/manifest.json`. Bump each pack's `version` so installed copies update. The app reads the manifest from `main`, so the Offline data screen works only after this branch merges.

Data for the app is rebuilt with `python scripts/build_ios_data.py --check` (about 25 s), which writes `Resources/sfgrid.bin` (9 MB) and `Resources/places.json` (0.9 MB). `scripts/check_geo.py` checks the Swift UTM math against pyproj.

Bundle `com.craigmerry.waterline`, team WYGG3JXWMG, 1.0. Builds run on the MacInCloud Mac over SSH from the Pi; there is no GitHub Actions job.

```bash
SSHOPTS="-i ~/.ssh/macincloud_ed25519 -o BatchMode=yes"
MAC=user273508@LA688.macincloud.com
rsync -az --delete -e "ssh $SSHOPTS" ios/ $MAC:waterline-ios/
ssh $SSHOPTS $MAC 'cd waterline-ios && ~/bin/xcodegen generate && xcodebuild -project Waterline.xcodeproj -scheme Waterline -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"'
```

That unsigned build is the free compile check. A signed archive goes to TestFlight, one upload per working session; unlock the keychain in the same SSH connection as the archive.

## Gotchas

- ARKit doesn't run in the Simulator; test on a device.
- Datum: ft MLLW = ft NAVD88 + (NAVD88 − MLLW on the station datum). In SF that's −0.06 ft. Before Nov 6 the project had this sign backwards everywhere, which put levels 0.12 ft low.
- The ground anchor assumes the pavement the camera finds is the ground the lidar describes. On a slope, GPS error (±15 ft) shifts it by slope × error, so the UI says "±0.5 ft, more on slopes".
- "Bay reaches here at" ignores seawalls the 5 m grid can't see and water coming up through storm drains. Both are screening limits, and the About sheet says so.
- `Waterline.xcodeproj` is generated, so edit `project.yml`, not the project file.

## TestFlight

`archive_upload.sh` archives, signs with the team's distribution identity and uploads in one go. Run it on the Mac with the keychain password piped in the same SSH connection (each connection is a new security session):

```bash
ssh $SSHOPTS $MAC 'cd waterline-ios && KEYCHAIN_PASSWORD=$(cat) ./archive_upload.sh 68T2S87K39 <ISSUER_ID>' < <(op item get <id> --vault Civqo --fields password --reveal)
```

Bump `CURRENT_PROJECT_VERSION` in `project.yml` before every upload. Uploads are capped at about 20 per version per day, so batch changes into one upload per session.

## Region packs and live data

`packs/manifest.json` has `groups` (one per place) and every pack names its `group`. An older build ignores both and shows a flat list.

A place's layers come from the bundle (SF), a downloaded layers pack, or `LiveLayers`, which reads FEMA and USACE and caches 0.1 degree cells. City drains and requests come from the feeds in the group's `live` block and are cached in 0.02 degree cells for a week. A rate limit isn't cached, so a city is never recorded as empty because it was busy.

Rebuild on the Mac, not the Pi:

```bash
ssh $SSHOPTS $MAC 'cd ~/waterline-build && .venv/bin/python -u scripts/build_region_packs.py scenes dem ground manifest'
```

## Simulator screenshots

XCUITest doesn't run on the headless Mac, so Debug builds read launch settings instead:

| Setting | Effect |
|---|---|
| `WL_PIN=37.7636,-122.4148` | pins that spot, as a tap on the Map would |
| `WL_TAB=map` | opens on the Map tab |
| `WL_SCROLL=coast` (or `enso`, `river`, `rain`) | scrolls the Here tab to that card once the report loads |
| `WL_3D=1` | opens the 3D ground for the spot |
| `-storm "100-yr day"` (launch argument) | picks the storm in the 3D view and Map |

```bash
D=B996B700-BDFB-4C09-90AB-E9CBFE09837B   # iPhone 17 Pro Max: 1320 x 2868, the App Store 6.9 inch size
xcrun simctl privacy $D grant location com.craigmerry.waterline
xcrun simctl status_bar $D override --time "9:41" --batteryState charged --batteryLevel 100
SIMCTL_CHILD_WL_PIN=37.7636,-122.4148 SIMCTL_CHILD_WL_SCROLL=coast xcrun simctl launch $D com.craigmerry.waterline
sleep 45 && xcrun simctl io $D screenshot coast.png
```
