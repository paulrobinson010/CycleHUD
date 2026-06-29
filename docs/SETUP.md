# CycleHUD — enabling Health & the Watch app

The phone app builds and runs as-is. Heart rate, calories, saving rides to
Apple Health, and the Watch app need a few one-time steps in Xcode that can't be
scripted. **All of these require a paid Apple Developer account** — on a free
personal team the HealthKit capability won't provision and the build will fail,
so only do these if you're on the paid program. The core ride/radar app works
either way.

Estimated time: ~5 minutes.

## 1. HealthKit on the iPhone app (saves rides + reads heart rate)

1. Select the project → **CycleHUD** target → **Signing & Capabilities**.
2. Click **+ Capability** → add **HealthKit**.
3. That's it — the usage-description strings are already in `Info.plist`.

Now tapping **Stop** on a ride saves a cycling workout (distance, duration,
calories, GPS route) to Apple Health.

## 2. Add the Watch app target

1. **File → New → Target… → watchOS → App**.
2. Product Name: **CycleHUDWatch**. Make sure it's created as a companion to the
   **CycleHUD** app (Xcode offers this; it sets the companion bundle id and
   pairing automatically). Interface **SwiftUI**, Language **Swift**.
3. Xcode generates a couple of template files (an `…App.swift` and a
   `ContentView.swift`) in the new watch target. **Delete those two template
   files** (move to Trash) to avoid a duplicate `@main`.
4. Add the prepared Watch sources: drag the three files from the repo's
   **`CycleHUDWatch/`** folder into the watch target in Xcode —
   `CycleHUDWatchApp.swift`, `WatchSessionManager.swift`, `WatchContentView.swift`.
   In the dialog, tick the **CycleHUDWatch** target (uncheck the iOS CycleHUD
   target). Don't add them to the iPhone app.
5. Watch target → **Signing & Capabilities**:
   - **+ Capability → HealthKit**.
   - **+ Capability → Background Modes**, then tick **Workout processing**.
6. Watch target → Info: add **Privacy - Health Share Usage Description** and
   **Privacy - Health Update Usage Description** (any short text, e.g. "Used to
   measure heart rate during a ride").
7. Set the watch target's deployment to **watchOS 10** or later.

## 3. Run it

- Build/run the **CycleHUD** (iPhone) scheme to your phone.
- Build/run the **CycleHUDWatch** scheme to your Apple Watch (first install can
  take a minute).
- Start a ride on the phone. The watch automatically starts a workout session,
  streams your heart rate back (Calories + Heart Rate tiles light up), mirrors
  your speed/distance/radar state, taps your wrist for approaching vehicles
  (escalating as they close in), and warns with a distinct buzz + RADAR OFF
  banner if the radar drops out mid-ride.
- Tap **Stop** → the ride is saved to Apple Health with its route.

## 3a. WeatherKit (rain nowcast — optional)

The ride screen can show a short-term rain forecast (Apple WeatherKit). The code
+ entitlement are already in place; you just enable the service once:

1. **developer.apple.com → Certificates, Identifiers & Profiles → Identifiers →**
   your **App ID** → tick **WeatherKit** under Capabilities, Save. (Allow a few
   hours after first enabling — Apple's docs note WeatherKit can take time to
   start serving for a new App ID.)
2. In Xcode, **CycleHUD target → Signing & Capabilities → + Capability →
   WeatherKit** (the `com.apple.developer.weatherkit` entitlement is already in
   `CycleHUD.entitlements`).
3. Build/run. The rain pill appears on the ride screen when rain is current or
   coming; turn it off under **Settings → Weather**.

Notes:
- **Free** up to 500k calls/month with your Apple Developer membership.
- **Attribution** to Apple Weather is shown in the pill's detail sheet (required
  by Apple).
- **Region:** minute-by-minute precipitation isn't available everywhere; where
  it's missing the app falls back to an hourly estimate automatically.
- **To verify on first run:** that `WeatherManager.mmPerHour(_:)` produces
  sensible mm/hr values (the one unit worth sanity-checking on a real device),
  and that `minuteForecast` returns data in your area.

## 3b. Translations (optional)

The app is localization-ready. To add languages:

1. **File → New → File → String Catalog**, name it **Localizable**, add to the
   **CycleHUD** target. Build once — Xcode auto-extracts every UI string (all the
   `Text("…")` and `String(localized: "…")` literals) into `Localizable.xcstrings`.
2. In the catalog editor, hit **+** to add a language and fill in translations
   (or export XLIFF for a translator and re-import).

Numbers are already locale-aware: `Fmt` (in `Format.swift`) formats values with
the device's decimal mark and digit grouping (e.g. `24,3` / `1 234`). The
rider's chosen **units** (km vs mi) stay separate and user-controlled. The Watch
app would take its own String Catalog in the watch target the same way.

## 4. Watch-face complication (optional)

The app icon is already wired up (`CyleHUDWatch Watch App/Assets.xcassets/AppIcon`),
so the app shows its icon on the watch home screen. A **complication** (the
tappable CycleHUD glyph on a watch face) is a separate **Widget Extension**
target — set it up once:

1. **File → New → Target… → watchOS → Widget Extension**. Name it
   **CycleHUDComplication**, **uncheck** "Include Configuration App Intent", and
   make sure it's embedded in the **CycleHUDWatch** app.
2. Xcode generates two files: a **`…Bundle.swift`** (the `@main` `WidgetBundle`)
   and a sample widget ("ExampleWidget"). Wire them to CycleHUD:
   - In the **sample widget file**, replace its contents with the code from
     **`CycleHUDComplication/CycleHUDComplication.swift`** (note: that struct has
     **no** `@main`).
   - In the **`…Bundle.swift`**, set its body to just `CycleHUDComplication()`
     (delete any `ExampleWidget()` / Control / Live Activity entries). The
     `@main` stays on the bundle — only one `@main` is allowed per target, so the
     widget struct must not have one.
3. Add the logo: select the widget's own **Assets.xcassets** (Xcode created it in
   the new target's folder) → drag in a 1024×1024 PNG → name the image set
   **AppLogo** (that's the name the code draws). A copy of the icon is at
   `CycleHUD/Assets.xcassets/AppIcon.appiconset/CycleHUD.png`.
4. Build/run the **CycleHUDComplication** scheme to the watch, then long-press a
   watch face → **Edit** → add **CycleHUD** to a complication slot.

This is a static "launch the app" tile that shows the CycleHUD logo — no data
sharing needed. To show live speed/threat on the face later, share ride state
from the watch app to the widget via an **App Group** and read it in the
timeline.

> Watch faces render most complication slots **tinted/monochrome**, so the logo
> may appear as a single-colour silhouette rather than full colour — that's the
> system styling, not a bug. If it looks like an indistinct blob, a simple
> high-contrast SF Symbol (e.g. `dot.radiowaves.left.and.right`) reads more
> clearly; swap `Image("AppLogo")` for `Image(systemName: …)` in the code.

## Notes

- The watch's own workout is intentionally **discarded** on stop — the phone
  saves the single authoritative workout (it has the GPS route), so you won't get
  duplicates in Health.
- Calories are an HR-based estimate (Keytel formula) using your weight (Settings
  → Rider, or read from Apple Health) and age/sex from Apple Health.
