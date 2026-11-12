# Waterline: App Store listing

The copy pushed to App Store Connect for app 6827234684 (`com.craigmerry.waterline`). Edit here, then push with `asc.py listing` from the appstore-submit skill.

| Field | Value |
|---|---|
| Name | Waterline: Flood Forecasting |
| Subtitle | Flood risk where you stand |
| Primary category | Weather |
| Secondary category | Reference |
| Price | Free |
| Age rating | 4+ |
| Copyright | 2026 Craig Merry |
| Marketing URL | https://craigmerry.com/waterline/ |
| Support URL | https://github.com/craigm26/waterline/issues |
| Privacy policy URL | https://craigmerry.com/waterline/privacy/ |
| App Privacy label | Data Not Collected (set in the App Store Connect website; there is no API) |

## Promotional text

NOAA says a strong to very strong El Niño is likely this winter. See what a king tide, a 100-year storm or a failed drain would mean for the exact spot you stand on.

## Keywords

flood,tide,king tide,el nino,sea level,storm surge,rain,levee,river gauge,fema,lidar,drain,ar

## Description

Does it flood here? Waterline answers that for the spot you are standing on, anywhere in the United States, with no account and no setup.

It reads the height of the ground under you from USGS lidar, then compares it with the water that could arrive: the tide, the rain forecast, the nearest river, and the flood maps for your address.

HERE
- A plain verdict for your spot: low, some or higher flood risk, with the reasons listed in order of importance.
- The next 3 days: forecast rain hour by hour, the water it would leave at your spot, and how fast it drains.
- Tides from the nearest NOAA station, the highest tide this month, and how far above or below your ground it stands.
- River gauges within 50 miles, with stage, forecast and flood category from the National Weather Service.
- Your FEMA flood zone in plain words.
- What you can do: the storm drain to check, where higher ground is, and how to get official alerts.

WHAT CAN STACK ON A HIGH TIDE
- This year's king tide, the sea running above prediction, the storm push from the record high water, and NOAA's sea level rise for 2050 and 2100, drawn as steps against the level that reaches you.
- NOAA's El Niño index, its strongest value since 1950, and NOAA's monthly outlook for how strong this winter's El Niño will be.
- NOAA's count of high tide flood days expected this year.

WHAT-IF STORMS
- The 10, 100 and 1000 year storms from NOAA Atlas 14, played hour by hour over your block.
- A 100 year day of rain landing on a king tide, when drains cannot empty.
- In California, the ARkStorm 2.0 megastorm scenarios and the winter of 1861-62.
Every what-if is labelled as a what-if. None of them is a forecast.

MAP AND 3D
- Tap anywhere to check that spot.
- Drains, low spots, levees, floodwalls, pump stations, flood zones, river gauges and past flooding reports, each with its source.
- The ground of your block in 3D with the computed rain water on it.

WATER LINE (CAMERA)
- See the water at its computed depth over the real street through the camera, beside a staff gauge and a person for scale.
- On iPhones with LiDAR, measure your doorstep or curb and see which scenarios go over it.
- Point the phone at the horizon to find river gauges, drains and higher ground by direction.

CITIES WITH MORE DETAIL
San Francisco is built in. Sacramento, New Orleans, Miami, Norfolk, Charleston, Houston, New York City and Boston have offline data packs you can download, with ground heights, the low basins rain collects in, levees and local data.

WHERE THE NUMBERS COME FROM
NOAA, the National Weather Service, USGS, FEMA, the US Army Corps of Engineers, California DWR and city open data. Every number is marked as official, derived or assumed, and links to its source. A water surface is drawn only from a computed depth.

PRIVACY
No accounts, no ads, no analytics. The app sends the coordinates of the spot you check only to the public data services that answer for it.

IMPORTANT
Waterline is a screening tool. It is not an engineered flood model, not an official forecast, and not a warning service. For emergencies follow your local officials and the National Weather Service.

## Review notes

No account or sign-in is needed, and there are no purchases.

How to test without being at a flood-prone place: open the Map tab, tap any spot (for example 17th St and Folsom St in San Francisco, or downtown Sacramento), then tap Details. The Here tab shows the full report for that spot. If location permission is denied, the Map tab still works this way.

Location (when in use only) reads the ground height, tides and forecast for where the person stands. The coordinates go directly from the phone to public government data services (NOAA, NWS, USGS, FEMA, USACE, California DWR, city open data). The developer runs no server and receives nothing.

Camera: the Water line tab draws computed water depth over the camera view and, on LiDAR iPhones, measures a step. Images are not saved or sent. The tab works best outdoors, pointed at the ground. Street placement uses ARKit geotracking and appears only where Apple supports it.

Motion: the barometer measures how far a floor is above the street. It is optional.

Offline data: the download button on the Here tab fetches public data packs from the app's public GitHub releases (https://github.com/craigm26/waterline). Each file is checked against a SHA-256 hash.

Safety framing: the app is a screening tool. It issues no alerts or warnings, and says so on the Here tab and in About. Every scenario that is not a forecast is labelled as a what-if or a stress test. All data is public US government or city open data, linked in About under Sources.

The app runs on iPhone. Data coverage is the United States.

## Screenshots

iPhone 6.9 inch (1320 x 2868), taken in the iPhone 17 Pro Max simulator at 17th St and Folsom St, San Francisco. Retake with the launch hooks in `ios/README.md`.
