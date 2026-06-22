# CycleHUD

My own cycling HUD as I don't like others! A clean, radar-first cycling HUD for
iPhone, built around a **Coospo TR70** (Garmin Varia–compatible) rear radar,
with standard BLE speed/cadence sensors and GPS for ride metrics.

<p align="center">
  <img src="docs/screenshot.png" alt="CycleHUD main riding screen, with the radar panel flooded red as a vehicle closes in" width="320">
</p>

## Features

- **Rear radar lane** — vehicles behind you are plotted by distance on a
  perspective lane, coloured by how fast/close they are. The whole panel glows
  amber→red as a threat closes in.
- **Audible new-car alert** — a distinctive double-beep the moment a *new*
  vehicle is detected (each car beeps once, persisting cars don't re-trigger).
  Plays over music and ignores the silent switch. Toggle in Settings.
- **Live metrics** — current speed, average speed (moving time only), distance,
  elapsed moving time, cadence, total ascent (barometer-based when available,
  GPS-altitude fallback otherwise), plus heart rate and calories when an Apple
  Watch is paired.
- **Apple Health** — tapping Stop saves a cycling workout (distance, duration,
  calories, GPS route) to Apple Health. Requires the HealthKit capability (see
  Setup).
- **Ride control** — Start / Pause / Resume / Stop.
- **Auto-pause / auto-resume** — pauses automatically after you're stopped
  (< 1 km/h) for 5 s, and resumes ~1 s after you start moving again.
- **Speed source** — uses the wheel sensor when connected, falls back to GPS.
- **Selectable units** — asked on first launch, changeable any time.
- **Remembered sensors** — configured devices are saved and auto-reconnect on
  every launch, retrying indefinitely. The top-bar Radar/Sensor icons show live
  state: green check = connected, spinner = connecting, rotating arrow =
  reconnecting, red triangle = Bluetooth unavailable, grey = not set up.
- **Demo mode** — Settings → Demo → *Start radar demo* plays a one-time preview
  on the main screen of low (yellow), medium (orange) and high (red) threats
  with the beep, so you can see/hear what to expect. It runs through once and
  stops; starting a ride also stops it.

## Build & run

1. Open `CycleHUD.xcodeproj` in **Xcode 16 or newer**.
2. Select your iPhone as the run destination.
3. Set your Apple Developer team: target **CycleHUD → Signing & Capabilities →
   Team**. (Personal/free teams work for installing on your own phone.)
4. Build & run (⌘R). Approve Bluetooth and Location prompts on first launch.

> Requires a physical iPhone — Bluetooth LE and GPS don't work in the Simulator.
> Deployment target is iOS 17.

### Health & Watch setup

Heart rate, calories, saving rides to Apple Health, and the Watch app need a few
one-time Xcode steps (HealthKit capability + adding the watch target) and a paid
Apple Developer account. The full walkthrough is in **[docs/SETUP.md](docs/SETUP.md)**.
The watch sources are ready in the `CycleHUDWatch/` folder; the phone already
includes the WatchConnectivity link (heart rate in, mirror display + new-car
wrist haptics out). The core ride/radar app runs without any of this.

### Pairing sensors

Tap the antenna icon (top right) → **Scan** → tap your radar and your
speed/cadence sensor. They reconnect automatically on later launches. The app
labels each device as *Radar* or *Speed / Cadence* once connected.

## Sensor protocols

- **Radar** — Varia rear-view radar service `6A4E3200-…`, measurement
  characteristic `6A4E3203-667B-11E3-949A-0800200C9A66`. Payload is one
  page/counter byte followed by 3 bytes per threat: `[id, distance(m),
  approach speed(km/h)]`. New cars are detected by a previously-unseen threat id.
- **Speed / cadence** — standard Bluetooth SIG CSC service `0x1816`,
  measurement characteristic `0x2A5B`.

### Things you may want to tune on the bike

These live in code and are easy to adjust:

- **Wheel circumference** — Settings → Speed Sensor (default 700×25c). Required
  for accurate sensor speed.
- **Threat severity colours** — `Threat.swift` (`level`): the speed/distance
  thresholds that map to yellow/orange/red.
- **Radar range shown** — `RadarView.swift` (`maxRange`, default 150 m).
- **Auto-pause timing/threshold** — `RideManager.swift`
  (`movingThresholdMps`, `autoPauseDelay`, `autoResumeDelay`).
- **Alert tone** — `AudioAlerts.swift` (`makeDoubleBeepWAV`).

> The radar byte layout is from the community-documented Varia protocol
> (pycycling / Garmin Radar Data BLE program). If your TR70 firmware reports
> distances or speeds that look off, the parser in `BluetoothManager.parseRadar`
> is the single place to adjust.

## Project layout

```
CycleHUD/
  CycleHUDApp.swift          App entry, wires managers together
  Theme.swift                Colours & fonts
  Models/                    Units, Threat
  Settings/                  AppSettings (persisted)
  Managers/
    BluetoothManager.swift   Scanning, radar + CSC parsing
    LocationManager.swift    GPS speed & distance fixes
    RideManager.swift        Ride state machine, auto-pause, averages
    AudioAlerts.swift        Synthesised beep
  Views/
    RideView.swift           Main radar-first screen
    RadarView.swift          The radar lane visualisation
    MetricTile.swift         Metric tiles
    PairingView.swift        Sensor pairing
    SettingsView.swift       Settings
    UnitsOnboardingView.swift First-launch units prompt
```
