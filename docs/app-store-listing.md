# CycleHUD — App Store listing copy

Reference for App Store Connect fields. Character limits noted per field.

## App Name (max 30)
```
CycleHUD — Bike Radar HUD
```
(25 chars. Alternative: just `CycleHUD`.)

## Subtitle (max 30)
```
See cars approach from behind
```
(29 chars.)

## Promotional Text (max 170 — editable any time without review)
```
Your rear radar on a clean lane you can read at a glance, with Apple Watch wrist alerts the moment a vehicle approaches. Eyes on the road, not on your phone.
```

## Keywords (max 100, comma-separated, no spaces)
```
radar,bike,cycling,rear radar,road safety,commute,cadence,heart rate,speed,watch,ride,gps,tr70
```
(94 chars. `tr70` targets owners of the radar directly. Dropped `bicycle`
as redundant with `bike`/`cycling` to make room. See note on brands below.)

## Description (max 4000)
```
CycleHUD turns your rear radar into a clear, glanceable heads-up display, so you always know what's coming up behind you without taking your eyes off the road.

Vehicles approaching from behind appear on a clean perspective lane, nearest at the top, and the whole panel glows amber to red as a car closes in. A green "Clear" shows when the road behind is empty. Pair an Apple Watch and you'll feel it too: a tap for each new vehicle, faster as it nears, and a distinct buzz if the radar ever drops out. Eyes up, hands on the bars.

BUILT FOR THE RIDE
- Rear-radar lane, colour-coded by how fast and close a vehicle is
- Apple Watch wrist alerts that escalate with proximity
- Optional new-vehicle beep through the phone
- Live metrics: speed, average, distance, time, cadence, ascent, heart rate and calories
- Every ride saved as an Apple Health workout (optional)
- Ride summary and history with a map of your route
- See exactly where vehicles passed you, each one pinned on the map with the distance and speed to review afterwards
- Heart-rate warning that flashes the display and buzzes your wrist
- Light or dark theme, plus a fixed-landscape layout for your handlebars

WORKS WITH YOUR SENSORS
Built around the Coospo TR70 rear radar, and also works with Garmin Varia-compatible radars and standard Bluetooth speed and cadence sensors. Speed falls back to GPS when no sensor is connected.

PRIVATE BY DESIGN
No accounts. No servers. No tracking, ads or analytics. Your location, heart rate and ride data stay on your device and in Apple Health, which you control.

CycleHUD is a focused, no-nonsense tool made by a rider who wanted exactly this, and nothing more.
```

## What's New (first release)
```
First release of CycleHUD: a rear-radar heads-up display with Apple Watch wrist alerts, ride summaries with vehicle-pass logging on a map, and Apple Health workouts.
```

## What's New (1.5) — en-US, 4000 char limit
```
This is a big one. CycleHUD learns to navigate — and to race you.

ROUTES (optional, off by default)
• Plan rides on a map: tap a start and waypoints, and the path snaps to quiet roads and cycle paths. Loop back to the start, or pick a separate finish.
• Follow a route on a live street map right in the radar panel — the radar instantly takes over whenever a vehicle approaches.
• Pick a route from far away and CycleHUD plots a lead-in leg to the start.
• Spoken turn alerts ("left turn ahead") with a wrist tap as each bend approaches.
• Live traffic on the route map: congestion and closures, straight from Apple Maps.
• The whole route's elevation profile, with your position and the gradient just ahead — as a strip on the map or a full-width Distance & Climb tile.
• Share routes as plain GPX files and import from anywhere (Strava, Komoot, RideWithGPS, a friend's export).

GHOST RIDER
• Complete a route once and that run becomes its best. Every ride after races it: a live ahead/behind readout, and a ghost marker riding the map beside you.
• Beat your ghost and the new run takes over. Ghosts even travel inside shared GPX files — so you can race a friend's best, or any recorded ride you import.

UPCOMING JUNCTIONS (optional, off by default)
• A tile or map badge shows the next intersection ahead — its real layout and a live distance countdown, powered by OpenStreetMap. Following a route? The arm your route takes glows green.

ALSO NEW
• Rate your effort (1–10) after each ride and it's saved to Apple Health's training load (iOS 18+).
• Crash SOS now mirrors to Apple Watch: dismiss it or call your emergency contact straight from the wrist.
• iCloud sync: rides, routes and ghosts back up to your own iCloud and follow you to a new phone. No accounts, ever.
• Multi-page tile layouts, a customizable grid, and new Wind, Compass, Junction and Distance & Climb tiles.

FIXES
• Auto-pause reliably resumes (position-based check), out-and-back roads no longer confuse distance-remaining or junction guidance, smoother route matching on long straights, and Apple Watch phantom-workout fixes.

As always: no accounts, no CycleHUD servers, no tracking. The optional junction and routing features fetch open road data (OpenStreetMap, BRouter) and are clearly disclosed in Settings and the privacy policy.
```

## URLs
- Marketing URL: `https://paulrobinson010.github.io/CycleHUD/`
- Support URL: `https://paulrobinson010.github.io/CycleHUD/` (or the privacy page)
- Privacy Policy URL: `https://paulrobinson010.github.io/CycleHUD/privacy.html`

## Category
- Primary: Health & Fitness  (Secondary: Sports)

## Note on brand keywords
`tr70` is a model number (lower trademark risk) and targets radar owners
directly, so it's included. The brand names `varia` and `coospo` are
trademarks — stating factual compatibility in the **description** is fine, but
brand names in the **keywords** field can occasionally trigger a metadata
rejection, so they're left out. If you want the extra search traffic you can try
adding `coospo,varia`, just be ready to remove them if review flags it.
