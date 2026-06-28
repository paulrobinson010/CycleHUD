# CycleHUD — design notes

A running log of notable decisions: features **considered and rejected**, and
ideas **parked pending validation**, so the reasoning isn't lost.

## Parked / needs field validation

### Running mode — rear radar clipped to a belt/shorts
**Idea:** reuse the TR70 rear radar for *running* on tight country lanes, to warn
of cars (and ideally bikes) approaching from behind. Radar held by a 3D-printed
clip on a waistband/race-belt. Possibly **watch-only** (no phone needed on a run).

**Verdict: feasible and potentially genuinely useful** (runners already use Garmin
Varia radars this way), but must be **field-validated before investing** in a
mount or a standalone watch build. The software is mostly reuse; the risks are
physical and, if watch-only, platform constraints.

Mostly free:
- The TR70 BLE protocol is already decoded (`BluetoothManager`) — reusable as-is.
- Wrist haptics are already built and are ideal for running (eyes up, no screen).
- Swapping the HealthKit workout type to running is trivial.

Pitfalls (in rough order of risk):
1. **Gait/platform-motion noise (biggest unknown).** The radar's target tracking
   assumes a smooth-moving bike. Clipped to the body it bobs, sways and rotates
   with each stride/hip turn, injecting Doppler noise and aim wander — expect more
   false alerts and jitter than on a bike. Only testing answers this.
2. **Mount stability/orientation.** Must point rearward, level and vertical (beam
   pattern depends on it). A snug race-belt at the *low centre back* is far more
   stable than shorts. The 3D print is the critical part — prototype stability
   first.
3. **Low mounting height → ground/verge clutter** (more false positives than a
   seatpost mount).
4. **Bikes are the weak case** (and a wanted target): small radar cross-section,
   low closing speed when overtaking a slow runner → late/unreliable detection.
   Cars detect well; don't count on bikes.
5. **Line-of-sight only** (inherent): nothing seen around hedges/bends until in
   view — same as cycling, more noticeable on twisty lanes.
6. **Watch-only is appealing but risky.** watchOS supports CoreBluetooth central,
   so a standalone watch app could connect to the TR70 directly. But the radar
   needs a ~2 s keepalive write, and watchOS throttles background timers when the
   wrist is down — even within a workout session the cadence may be coalesced,
   stalling the stream. Safe fallback is the current architecture (phone does BLE
   + keepalive, watch does haptics); watch-only is a bigger, riskier build.

De-risk cheaply, in order:
1. Prove detection works at all while running — scrappy belt mount + existing app,
   one or two country runs, count real cars vs. false alerts vs. missed bikes.
2. If acceptable → build a **phone-in-pocket + watch-haptics** run mode (low risk,
   reuses everything).
3. Only if that's great and phone-free is wanted → tackle **standalone watch BLE**,
   validating keepalive reliability early.

## Considered and rejected

### In-app "Now Playing" / universal media controls
**Idea:** a tab (or ride-screen transport bar) showing whatever media is playing
— Amazon Music, Audible, Apple Music, etc. — with play/pause/skip, for quick
control with bone-conduction headphones on isolated rides.

**Rejected — iOS platform limitation.** There is no public API to read or
control "whatever is currently playing" across apps. The universal Now Playing
surface seen in Apple's Workout app, Control Center, the lock screen and CarPlay
is a *system* experience backed by the private **MediaRemote** framework, which
Apple reserves for its own UI; any App Store app using it is auto-rejected (and
Apple further restricted MediaRemote for third parties on iOS 16+, so even a
personal/sideloaded build is unreliable).

Apps only get a **write-only** relationship with that surface: they publish
their own metadata via `MPNowPlayingInfoCenter` and handle transport via
`MPRemoteCommandCenter` *when they are the active audio app*. The system
aggregates and displays it; reading the aggregate back is not exposed.

The only media a third-party app can read/control is **Apple Music** (via
MusicKit's `SystemMusicPlayer` / `MPMusicPlayerController.systemMusicPlayer`).
That would be an Apple-Music-only panel — no Amazon Music or Audible — which
isn't worth a dedicated UI given listening is spread across services.

**What to use instead:** the Apple Watch **Now Playing** app (one swipe from the
workout screen) and the iPhone **Control Center** media tile already provide
universal transport across all those apps, with large buttons. CycleHUD's job is
just to coexist cleanly with them — which it does: the new-vehicle beep mixes/
ducks over other audio rather than taking it over.
