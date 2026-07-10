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

## 3b. iCloud sync (rides, routes & ghosts — optional)

`CloudSync` mirrors the ride history and routes (with their ghosts) into the
app's own iCloud Drive container, so data survives a lost phone. The code is
in place; enable the capability once:

1. In Xcode, **CycleHUD target → Signing & Capabilities → + Capability →
   iCloud**, tick **iCloud Documents**, and add (＋) a container named
   `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)` (Xcode offers this default).
2. Build/run. The toggle lives under **Settings → Data → iCloud sync** (on by
   default); it warns in place if iCloud is unavailable on the device.

Without the capability (or with iCloud Drive off) the feature quietly does
nothing — everything else works as before.

## 3c. Live tracking (share-my-ride link — optional)

Live tracking publishes the rider's position to the app's own **CloudKit
public database** under a random token; the website (`docs/live.html`) reads
it back, so followers just open a link — no app, no account. To enable:

1. In Xcode, on the **CycleHUD target → Signing & Capabilities → iCloud**
   capability, additionally tick **CloudKit** (the container stays
   `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)`). The entitlement is already in the
   repo; Xcode just needs to register the container.
2. Run the app once and start a ride with **Settings → Live tracking** on —
   the first save creates the `LiveRide` record type in the **Development**
   environment.
3. In the [CloudKit Dashboard](https://icloud.developer.apple.com/) select the
   container, then:
   - **Schema → Deploy Schema Changes…** to push `LiveRide` to **Production**.
   - **Settings → Tokens & Keys → ＋ API Token** — and make sure the
     environment breadcrumb at the top says **Production** first: tokens are
     scoped to the environment they're created in, and one minted while the
     console sits in Development only ever authenticates against
     Development (`AUTHENTICATION_FAILED` from the production URL). Allowed
     Origins: restrict to the site's domain. Paste the token into
     `docs/live.html` as `API_TOKEN`.
4. Push the site. Share links look like
   `https://cyclehud.robbo-online.uk/live.html#<token>`; they update every
   15 s and go dead the moment the ride stops (the record is deleted).

> **Whenever an app update adds fields to `LiveRide`** (e.g. the encrypted
> `payload` field that replaced the original plaintext ones), the schema has
> to catch up: run one ride on a **development** build so the new fields
> appear in the Development schema, then **Deploy Schema Changes →
> Production** again. Production rejects unknown fields, so
> TestFlight/App Store saves fail until the deploy.

The published record is **end-to-end encrypted**: the app seals each update
with a per-ride AES key carried only in the share link's `#` fragment, which
browsers never send to servers. The dashboard (and the web token) can only
ever see ciphertext — there is nothing sensitive to protect in the CloudKit
console beyond keeping queryable indexes off.

## 3d. Strava upload (optional)

Uploads go straight from the phone to Strava's API — no middleman server.
You need your own (free) Strava API application:

1. On [strava.com/settings/api](https://www.strava.com/settings/api) create an
   API application. Set **Authorization Callback Domain** to `localhost`
   (the app's OAuth redirect is `cyclehud://localhost`).
2. Copy the **Client ID** and **Client Secret** into `CycleHUD/Info.plist`
   under the `StravaClientID` / `StravaClientSecret` keys.
3. Build/run, then **Settings → Strava → Connect Strava** — the Strava login
   opens in a system sheet. Tokens are stored in the Keychain.
4. Upload from the button on any ride summary, or flip on **Auto-upload
   rides** to send every finished ride.

## 3b. Translations (optional)

The app is localization-ready. To add languages:

1. **File → New → File → String Catalog**, name it **Localizable**, add to the
   **CycleHUD** target. Build once — Xcode auto-extracts every UI string (all the
   `Text("…")` and `String(localized: "…")` literals) into `Localizable.xcstrings`.
2. In the catalog editor, hit **+** to add a language and fill in translations
   (or export XLIFF for a translator and re-import).

Numbers are already locale-aware: `Fmt` (in `Format.swift`, one per target)
formats values with the device's decimal mark and digit grouping (e.g. `24,3` /
`1 234`). The rider's chosen **units** (km vs mi) stay separate and
user-controlled. The **Watch app is prepped the same way** — add a second String
Catalog to the watch target (its strings already use `Text`/`String(localized:)`
and its numbers use the watch `Fmt`).

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
