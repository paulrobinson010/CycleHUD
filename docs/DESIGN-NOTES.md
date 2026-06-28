# CycleHUD — design notes

A running log of notable decisions, especially features that were **considered
and rejected**, so the reasoning isn't lost.

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
