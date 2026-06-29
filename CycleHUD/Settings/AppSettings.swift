import Foundation
import Combine

/// User-configurable settings, persisted to UserDefaults.
final class AppSettings: ObservableObject {

    private enum Keys {
        static let speedUnit = "speedUnit"
        static let distanceUnit = "distanceUnit"
        static let wheelCircumferenceMM = "wheelCircumferenceMM"
        static let riderWeightKg = "riderWeightKg"
        static let beepEnabled = "beepEnabled"
        static let hapticsEnabled = "hapticsEnabled"
        static let autoPauseEnabled = "autoPauseEnabled"
        static let keepScreenOn = "keepScreenOn"
        static let hasChosenUnits = "hasChosenUnits"
        static let radarDebugEnabled = "radarDebugEnabled"
        static let landscapeEnabled = "landscapeEnabled"
        static let hrWarningEnabled = "hrWarningEnabled"
        static let hrWarningBpm = "hrWarningBpm"
        static let saveWorkouts = "saveWorkouts"
        static let darkModeEnabled = "darkModeEnabled"
        static let weatherEnabled = "weatherEnabled"
        static let weatherAlertsEnabled = "weatherAlertsEnabled"
        static let appLanguage = "appLanguage"
    }

    /// A language the rider can pick in-app. Empty code = follow the device.
    struct AppLanguage: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let supportedLanguages: [AppLanguage] = [
        .init(code: "", name: "System"),
        .init(code: "en-GB", name: "English (UK)"),
        .init(code: "en-US", name: "English (US)"),
        .init(code: "de-DE", name: "Deutsch"),
        .init(code: "fr-FR", name: "Français"),
        .init(code: "it-IT", name: "Italiano"),
        .init(code: "es-ES", name: "Español"),
    ]

    private let defaults = UserDefaults.standard

    @Published var speedUnit: SpeedUnit { didSet { defaults.set(speedUnit.rawValue, forKey: Keys.speedUnit) } }
    @Published var distanceUnit: DistanceUnit { didSet { defaults.set(distanceUnit.rawValue, forKey: Keys.distanceUnit) } }
    @Published var wheelCircumferenceMM: Double { didSet { defaults.set(wheelCircumferenceMM, forKey: Keys.wheelCircumferenceMM) } }
    @Published var riderWeightKg: Double { didSet { defaults.set(riderWeightKg, forKey: Keys.riderWeightKg) } }
    @Published var beepEnabled: Bool { didSet { defaults.set(beepEnabled, forKey: Keys.beepEnabled) } }
    /// When on, a paired Apple Watch taps the wrist for vehicles behind you.
    /// Muted from the radar screen (or here) to quieten busy-town riding.
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) } }
    @Published var autoPauseEnabled: Bool { didSet { defaults.set(autoPauseEnabled, forKey: Keys.autoPauseEnabled) } }
    @Published var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: Keys.keepScreenOn) } }
    @Published var hasChosenUnits: Bool { didSet { defaults.set(hasChosenUnits, forKey: Keys.hasChosenUnits) } }
    /// Developer aid: shows the on-screen "Mark car" button for capturing radar
    /// timing when decoding a new/misbehaving radar. Off for normal riders.
    @Published var radarDebugEnabled: Bool { didSet { defaults.set(radarDebugEnabled, forKey: Keys.radarDebugEnabled) } }
    /// When on, the phone may rotate to landscape and the ride screen splits
    /// side-by-side (radar on the left, ride data on the right). Off keeps the
    /// app portrait-only as before.
    @Published var landscapeEnabled: Bool { didSet { defaults.set(landscapeEnabled, forKey: Keys.landscapeEnabled) } }
    /// When on, the heart-rate display turns red and the Watch double-buzzes once
    /// the rider's heart rate reaches `hrWarningBpm`.
    @Published var hrWarningEnabled: Bool { didSet { defaults.set(hrWarningEnabled, forKey: Keys.hrWarningEnabled) } }
    /// Heart-rate warning threshold in bpm (selected in 5-bpm steps, 120–220).
    @Published var hrWarningBpm: Int { didSet { defaults.set(hrWarningBpm, forKey: Keys.hrWarningBpm) } }

    /// When on, each finished ride is saved as an Apple Health workout.
    @Published var saveWorkouts: Bool { didSet { defaults.set(saveWorkouts, forKey: Keys.saveWorkouts) } }
    /// App appearance: off = light (white background), on = dark.
    @Published var darkModeEnabled: Bool { didSet { defaults.set(darkModeEnabled, forKey: Keys.darkModeEnabled) } }
    /// Short-term rain nowcast (Apple WeatherKit) shown on the ride screen.
    @Published var weatherEnabled: Bool { didSet { defaults.set(weatherEnabled, forKey: Keys.weatherEnabled) } }
    /// Notify (and buzz the Watch) when rain is imminent.
    @Published var weatherAlertsEnabled: Bool { didSet { defaults.set(weatherAlertsEnabled, forKey: Keys.weatherAlertsEnabled) } }
    /// In-app language override (BCP-47 code, or "" to follow the device).
    @Published var appLanguage: String {
        didSet { defaults.set(appLanguage, forKey: Keys.appLanguage); applyLanguage() }
    }

    /// The locale the app should display in — the override, or the device default.
    var appLocale: Locale {
        appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }

    /// Apply the language override: tell the system which localization to load
    /// (also takes full effect on next launch, incl. system permission dialogs)
    /// and point number formatting at the chosen locale immediately.
    private func applyLanguage() {
        if appLanguage.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([appLanguage], forKey: "AppleLanguages")
        }
        Fmt.locale = appLocale
    }

    /// The warning threshold to broadcast to the Watch — 0 when disabled.
    var effectiveHRWarningBpm: Int { hrWarningEnabled ? hrWarningBpm : 0 }

    init() {
        defaults.register(defaults: [
            Keys.speedUnit: SpeedUnit.kmh.rawValue,
            Keys.distanceUnit: DistanceUnit.km.rawValue,
            Keys.wheelCircumferenceMM: 2105.0,   // 700x25c default
            Keys.riderWeightKg: 0.0,             // 0 = not entered (no calories shown)
            Keys.beepEnabled: true,
            Keys.hapticsEnabled: true,
            Keys.autoPauseEnabled: true,
            Keys.keepScreenOn: true,
            Keys.hasChosenUnits: false,
            Keys.radarDebugEnabled: false,
            Keys.landscapeEnabled: false,
            Keys.hrWarningEnabled: false,
            Keys.hrWarningBpm: 200,
            Keys.saveWorkouts: true,
            Keys.darkModeEnabled: false,
            Keys.weatherEnabled: true,
            Keys.weatherAlertsEnabled: true,
            Keys.appLanguage: ""
        ])

        speedUnit = SpeedUnit(rawValue: defaults.string(forKey: Keys.speedUnit) ?? "") ?? .kmh
        distanceUnit = DistanceUnit(rawValue: defaults.string(forKey: Keys.distanceUnit) ?? "") ?? .km
        wheelCircumferenceMM = defaults.double(forKey: Keys.wheelCircumferenceMM)
        riderWeightKg = defaults.double(forKey: Keys.riderWeightKg)
        beepEnabled = defaults.bool(forKey: Keys.beepEnabled)
        hapticsEnabled = defaults.bool(forKey: Keys.hapticsEnabled)
        autoPauseEnabled = defaults.bool(forKey: Keys.autoPauseEnabled)
        keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        hasChosenUnits = defaults.bool(forKey: Keys.hasChosenUnits)
        radarDebugEnabled = defaults.bool(forKey: Keys.radarDebugEnabled)
        landscapeEnabled = defaults.bool(forKey: Keys.landscapeEnabled)
        hrWarningEnabled = defaults.bool(forKey: Keys.hrWarningEnabled)
        hrWarningBpm = defaults.integer(forKey: Keys.hrWarningBpm)
        saveWorkouts = defaults.bool(forKey: Keys.saveWorkouts)
        darkModeEnabled = defaults.bool(forKey: Keys.darkModeEnabled)
        weatherEnabled = defaults.bool(forKey: Keys.weatherEnabled)
        weatherAlertsEnabled = defaults.bool(forKey: Keys.weatherAlertsEnabled)
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? ""
        applyLanguage()
    }

    var wheelCircumferenceMeters: Double { wheelCircumferenceMM / 1000.0 }
}
