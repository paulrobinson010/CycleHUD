# CycleHUD

A personal, quality-of-life cycling HUD for iPhone + Apple Watch, built around
the **Coospo TR70** rear radar. The focus is a **clear, glanceable UI**,
**wrist haptics** so you can keep your eyes on the road, and a clean finish that
saves each ride as an **Apple Health workout**. Garmin Varia–compatible radars
and standard BLE speed/cadence sensors work too.

<p align="center">
  <img src="docs/screenshot.png" alt="CycleHUD main riding screen, with the radar panel flooded red as a vehicle closes in" width="320">
</p>

## Features

- **Rear radar lane** — vehicles behind you are plotted by distance on a clean
  perspective lane, coloured by how fast/close they are. The whole panel glows
  amber→red as a vehicle closes in; a green “Clear” shows when the road is empty.
- **Apple Watch wrist alerts** — keep your eyes up and feel what's behind you:
  - a tap the moment a *new* vehicle appears,
  - escalating taps that get faster/stronger as it closes in,
  - a distinct **double-buzz** if the radar drops out mid-ride, with a red
    **RADAR OFF** banner so the wrist never shows a misleading “Clear”.
- **Reliable radar presence** — the TR70's ~2 Hz heartbeat is used to confirm
  the radar is really there. If it's switched off or out of range, the lane
  shows **NOT CONNECTED** within a few seconds (it's a safety device — it
  shouldn't pretend to be watching when it isn't).
- **Optional new-vehicle beep** — a distinctive double-beep through the phone,
  over music and ignoring the silent switch. Toggle in Settings.
- **Live metrics** — current speed, average speed (moving time only), distance,
  elapsed moving time, cadence, total ascent (barometer-based when available,
  GPS-altitude fallback otherwise), plus heart rate and calories when an Apple
  Watch is paired.
- **Apple Health workout** — tapping Stop saves a cycling workout (distance,
  duration, calories, GPS route) to Apple Health. Requires the HealthKit
  capability (see Setup).
- **Ride control** — Start / Pause / Resume / Stop, with **auto-pause /
  auto-resume** (pauses after you're stopped < 1 km/h for 5 s, resumes ~1 s
  after you move again).
- **Speed source** — uses the wheel sensor when connected, falls back to GPS.
- **Selectable units** — asked on first launch, changeable any time.
- **Remembered sensors** — configured devices are saved and auto-reconnect on
  every launch, retrying indefinitely. The top-bar Radar/Sensor icons show live
  state: green check = connected, spinner = connecting, rotating arrow =
  reconnecting, red triangle = Bluetooth unavailable, grey = not set up.
- **Demo mode** — Settings → Demo → *Start radar demo* plays a one-time preview
  on the main screen: low (yellow), medium (orange) and high (red) vehicles, the
  beep, the **escalating wrist taps**, and a closing **radar-off** wrist alert —
  so you can feel and fine-tune every alert before a ride. It runs through once
  and stops; starting a ride also stops it.

## Build & run

1. Open `CycleHUD.xcodeproj` in **Xcode 16 or newer**.
2. Select your iPhone as the run destination.
3. Set your Apple Developer team: target **CycleHUD → Signing & Capabilities →
   Team**. (Personal/free teams work for installing on your own phone.)
4. Build & run (⌘R). Approve Bluetooth and Location prompts on first launch.

> Requires a physical iPhone — Bluetooth LE and GPS don't work in the Simulator.
> Deployment target is iOS 17.

### Health & Watch setup

The Apple Watch app is central to the experience (wrist alerts + heart rate),
but it — along with saving rides to Apple Health — needs a few one-time Xcode
steps (HealthKit capability + adding the watch target) and a paid Apple
Developer account. The full walkthrough is in **[docs/SETUP.md](docs/SETUP.md)**.
The watch sources are ready in the `CyleHUDWatch Watch App/` folder; the phone
already includes the WatchConnectivity link (heart rate in; mirror display,
escalating new-car wrist taps, and the radar-off alert out). The core ride/radar
app still runs on the phone alone.

### Pairing sensors

Tap the antenna icon (top right) → **Scan** → tap your radar and your
speed/cadence sensor. They reconnect automatically on later launches. The app
labels each device as *Radar* or *Speed / Cadence* once connected.

## Sensor protocols

- **Coospo TR70 radar (primary)** — a proprietary BLE service, reverse-engineered
  from the CoospoRide app. The radar streams nothing until it's *enabled*: the
  app writes a control command to characteristic **FDB2** and resends it on a
  ~2 s keepalive, and the radar then streams frames on **FDB1**.
  - **Enable / keepalive:** write `B8 05 02 01 C0` to FDB2. Commands are
    `[opcode][len][params…][checksum]`, checksum = sum of the prior bytes & 0xFF.
  - **Data frame (FDB1):** `[0xC8][len][page][payload…][checksum]`. Page `0x24`
    is the threat list (target bytes, all-zero when clear); page `0x03` is a
    status heartbeat — used to confirm the radar is alive.
- **Garmin Varia–compatible radar (also supported)** — service `6A4E3200-…`,
  measurement characteristic `6A4E3203-…`. Payload is one page/counter byte then
  3 bytes per threat: `[id, distance(m), approach speed(km/h)]`.
- **Speed / cadence** — standard Bluetooth SIG CSC service `0x1816`,
  measurement characteristic `0x2A5B`.

New vehicles are detected by a previously-unseen threat id; the **Sensor
diagnostics** screen (Settings) shows live services, characteristics and raw
radar packets if you need to debug a sensor in the field.

### Things you may want to tune on the bike

These live in code and are easy to adjust:

- **Wheel circumference** — Settings → Speed Sensor (default 700×25c). Required
  for accurate sensor speed.
- **Threat severity colours** — `Threat.swift` (`level`): the speed/distance
  thresholds that map to yellow/orange/red.
- **Radar range shown** — `RadarView.swift` (`maxRange`, default 150 m).
- **Radar presence timeout** — `BluetoothManager.swift` (`radarDataTimeout`,
  default 4 s): how long without a heartbeat before showing NOT CONNECTED.
- **Auto-pause timing/threshold** — `RideManager.swift`.
- **Watch haptic patterns** — `WatchSessionManager.swift` (`playHaptic` for the
  new-car/proximity taps, `playEventHaptic` for the radar-off double-buzz).
- **New-vehicle beep** — `AudioAlerts.swift` (`makeDoubleBeepWAV`).

> The TR70 threat-byte layout within page `0x24` is still being confirmed from
> real traffic (a pedestrian is below a car radar's detection threshold, so it
> only populates with an actual vehicle). `BluetoothManager.parseCoospoRadar`
> decodes the FDB1 frame and is the single place to adjust it; the Varia format
> is handled by `parseRadar`.

## Project layout

```
CycleHUD/
  CycleHUDApp.swift          App entry, wires managers together
  Theme.swift                Colours & fonts
  Models/                    Units, Threat
  Settings/                  AppSettings (persisted)
  Managers/
    BluetoothManager.swift   Scanning, TR70 + Varia radar, CSC, radar liveness
    LocationManager.swift    GPS speed & distance fixes
    RideManager.swift        Ride state machine, auto-pause, demo, Watch mirror
    WatchConnectivityManager.swift  iPhone⇄Watch link (HR in, alerts out)
    HealthKitManager.swift   Saves the cycling workout to Apple Health
    AudioAlerts.swift        Synthesised new-vehicle beep
    Calories.swift           HR-based calorie estimate
    AppLog.swift             On-device diagnostics log
  Views/
    RideView.swift           Main radar-first screen (+ Mark-car log button)
    RadarView.swift          The radar lane visualisation
    MetricTile.swift         Metric tiles
    PairingView.swift        Sensor pairing
    SettingsView.swift       Settings
    DiagnosticsView.swift    Live BLE services / radar packets
    UnitsOnboardingView.swift First-launch units prompt

CyleHUDWatch Watch App/      Watch app: glanceable mirror + wrist haptics
  CycleHUDWatchApp.swift     Watch app entry
  WatchSessionManager.swift  Workout session (HR), haptic patterns, link
  WatchContentView.swift     Watch face: speed/HR/distance + threat / RADAR OFF
```
