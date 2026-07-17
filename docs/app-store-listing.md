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
See every car behind you, follow quiet-road routes on a live map, and race the ghost of your own best ride — with Apple Watch alerts keeping your eyes on the road.
```
(163 chars.)

## Keywords (max 100, comma-separated, no spaces)
```
radar,bike,cycling,rear radar,route,navigation,ghost,commute,cadence,heart rate,speed,watch,tr70
```
(97 chars. Added `route,navigation,ghost` for 1.5; dropped `road safety`,
`ride`, `gps` — weak or implied terms. `tr70` targets radar owners directly.
See note on brands below.)

## Description (max 4000) — rewritten for 1.5
```
CycleHUD turns your rear radar into a clear, glanceable heads-up display — and now a quiet-roads navigator and a racing partner too. Always know what's coming up behind you, where you're going, and how you compare with your best, without taking your eyes off the road.

EYES BEHIND YOU
Vehicles approaching from behind appear on a clean perspective lane, nearest at the top, and the whole panel glows amber to red as a car closes in. A green "Clear" shows when the road behind is empty. Pair an Apple Watch and you'll feel it too: a tap for each new vehicle, faster as it nears, and a distinct buzz if the radar ever drops out. After the ride, every vehicle that passed you is pinned on your route map with its distance and speed.

ROUTES ON QUIET ROADS
Plan a ride by tapping a start and waypoints on a map — the path snaps to quiet roads and cycle paths, looping back to the start or finishing wherever you choose. While the road behind is clear, the radar panel becomes a live street map: your route ahead, live traffic and closures, the whole ride's elevation profile with the gradient coming up, and the next junction's real layout counting down — with the turn your route takes glowing green. Spoken turn alerts and wrist taps call each bend. Pick a route from across town and CycleHUD plots a lead-in to the start. The moment a vehicle appears behind you, the radar takes the screen back. Routes share as plain GPX and import from anywhere — Strava, Komoot, RideWithGPS, a friend's export.

RACE YOUR GHOST
Complete a route once and that run becomes its best. Every ride after is a race: a live ahead/behind readout and a ghost marker riding the map beside you. Beat it and the new run takes over. Ghosts travel inside shared GPX files, so you can race a friend's best — or import any recorded ride and chase it.

BUILT FOR THE RIDE
- Live metrics on customisable, swipeable tile pages: speed, cadence, heart rate, ascent, live gradient, wind (as headwind or tailwind), compass, rain nowcast and more
- Every ride saved as an Apple Health workout, with a post-ride effort rating for Health's training load (iOS 18+)
- Ride summaries with graphs you can scrub, laps, and your previous bests over the same stretches of road
- Optional crash detection: a hard impact followed by a stop starts an SOS countdown on the phone AND your watch — dismiss it or call your emergency contact straight from the wrist
- Heart-rate warning that flashes the display and buzzes your wrist
- iCloud sync: rides, routes and ghosts back up to your own iCloud and follow you to a new phone
- Light, dark and Cyberpunk themes, a digital-dash font, and a fixed-landscape layout for your handlebars

WORKS WITH YOUR SENSORS
Built around the Coospo TR70 rear radar, and also works with Garmin Varia-compatible radars, standard Bluetooth speed and cadence sensors and heart-rate straps. Speed falls back to GPS when no sensor is connected.

PRIVATE BY DESIGN
No accounts. No servers. No tracking, ads or analytics. Your data lives on your device, in Apple Health and in your own iCloud — all under your control. The optional routing and junction features fetch open road data (OpenStreetMap, BRouter) and say so plainly in Settings.

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

## What's New (1.6) — en-US, 4000 char limit
```
CycleHUD 1.6: your ride goes live — and the radar tells you more.

LIVE TRACKING (optional, off by default)
• Share a private link and someone can watch your ride live: position, the path so far, your planned route, speed, average and an ETA — updated every 15 seconds.
• End-to-end encrypted: the key travels only inside the link itself, so nobody without it — not even us — can see where you are. No accounts, no servers; it runs through your own iCloud.
• The link goes dead the moment you stop the ride.

RIDE ON YOUR LOCK SCREEN
• A Live Activity shows speed, distance, time and heart rate on the Lock Screen and in the Dynamic Island — and floods with the threat color the instant the radar sees a car behind you.
• Riding with the Watch app instead? One toggle turns it off.

THE RADAR SAYS HOW FAST
• Every vehicle on the lane now shows its closing speed beside its distance — how much faster than you it's approaching, straight from the radar.

POWER ZONES
• Set your FTP and the power tile colors by the classic 7 zones as you ride. Ride summaries add normalized power, intensity, and a time-in-zones bar.

ROUTES CELEBRATE
• Joining a route now toasts the time to beat; crossing the finish shows your time and the verdict against your best — with a spoken call-out and a wrist tap.
• The ghost glides smoothly along the road and faces the way it's riding, and the ghost and ETA readouts are twice the size.
• Ride any route in reverse — one-way roads are checked first and roundabouts re-routed the legal way around.
• Weather preview: pick a route and a start time and watch the ride play out — the map colored by the wind you'd actually meet at your predicted pace, hour by hour.
• While riding, the route tints by headwind and tailwind stretch.

CLIMBS AND INSIGHTS
• A climb card takes over the map as each climb begins: distance to the top, ascent left, and the gradient of what remains.
• Insights: weekly distance and climbing trends, personal records, and radar traffic statistics no other app has — vehicles detected, detections per km, your fastest overtake, and a map of everywhere cars passed you. All computed on your device.

TWO NEW LOOKS
• Cyberpunk goes full CRT: phosphor scanlines, a tube vignette, and random bursts of magnetic interference — politely suppressed whenever a car is behind you.
• And its antithesis: Unicorn. Pastel skies, candy tile rims, a hand-drawn font.

POLISH & FIXES
• Heart-rate graphs no longer start at zero; tap a Previous Bests stretch to light it up on the map and graphs.
• Units tuck neatly under each value; sensor status pills only show sensors you've set up.
• Big Apple Watch reliability fixes: the workout keep-alive can no longer die quietly mid-ride, and any accidental zero-time workouts clean themselves up automatically.
• The demo now rides a real route — the Central Park loop.

As always: no accounts, no CycleHUD servers, no tracking. Every network feature is optional and disclosed in Settings and the privacy policy.
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
