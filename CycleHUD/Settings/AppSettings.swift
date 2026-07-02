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
        static let voiceAlertsEnabled = "voiceAlertsEnabled"
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
        static let appLanguage = "appLanguage"
        static let metricTiles = "metricTilesV2"   // V2: default back to the original tile set
        static let showTileUnits = "showTileUnits"
        static let crashDetectionEnabled = "crashDetectionEnabled"
        static let emergencyContactName = "emergencyContactName"
        static let emergencyContactPhone = "emergencyContactPhone"
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
    /// When on, a spoken call-out ("car behind" + distance) announces each new
    /// vehicle — handy with bone-conduction headphones. Independent of the beep.
    @Published var voiceAlertsEnabled: Bool { didSet { defaults.set(voiceAlertsEnabled, forKey: Keys.voiceAlertsEnabled) } }
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
    /// In-app language override (BCP-47 code, or "" to follow the device).
    @Published var appLanguage: String {
        didSet { defaults.set(appLanguage, forKey: Keys.appLanguage); applyLanguage() }
    }
    /// The ride-screen metric tiles to show, in order (MetricKind raw values).
    @Published var metricTiles: [String] { didSet { defaults.set(metricTiles, forKey: Keys.metricTiles) } }

    /// The selected metrics as `MetricKind`s, dropping any unknown raw values.
    var metricKinds: [MetricKind] { metricTiles.compactMap(MetricKind.init(rawValue:)) }

    /// Show the unit label (km/h, bpm, …) next to each tile's value. Off frees
    /// the space for bigger numbers — for riders who know their units.
    @Published var showTileUnits: Bool { didSet { defaults.set(showTileUnits, forKey: Keys.showTileUnits) } }

    /// When on, a sharp impact during a ride starts an SOS countdown that texts
    /// the emergency contact your location.
    @Published var crashDetectionEnabled: Bool { didSet { defaults.set(crashDetectionEnabled, forKey: Keys.crashDetectionEnabled) } }
    @Published var emergencyContactName: String { didSet { defaults.set(emergencyContactName, forKey: Keys.emergencyContactName) } }
    @Published var emergencyContactPhone: String { didSet { defaults.set(emergencyContactPhone, forKey: Keys.emergencyContactPhone) } }

    /// The emergency contact, or nil when no phone number has been entered.
    var emergencyContact: (name: String, phone: String)? {
        let phone = emergencyContactPhone.trimmingCharacters(in: .whitespaces)
        guard !phone.isEmpty else { return nil }
        return (emergencyContactName, phone)
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
        Lang.apply(appLanguage)   // redirect String(localized:)/Text lookups live
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
            Keys.voiceAlertsEnabled: false,
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
            Keys.appLanguage: "",
            Keys.metricTiles: MetricKind.defaultOrder.map(\.rawValue),
            Keys.showTileUnits: true,
            Keys.crashDetectionEnabled: false,
            Keys.emergencyContactName: "",
            Keys.emergencyContactPhone: ""
        ])

        speedUnit = SpeedUnit(rawValue: defaults.string(forKey: Keys.speedUnit) ?? "") ?? .kmh
        distanceUnit = DistanceUnit(rawValue: defaults.string(forKey: Keys.distanceUnit) ?? "") ?? .km
        wheelCircumferenceMM = defaults.double(forKey: Keys.wheelCircumferenceMM)
        riderWeightKg = defaults.double(forKey: Keys.riderWeightKg)
        beepEnabled = defaults.bool(forKey: Keys.beepEnabled)
        voiceAlertsEnabled = defaults.bool(forKey: Keys.voiceAlertsEnabled)
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
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? ""
        let storedTiles = defaults.stringArray(forKey: Keys.metricTiles) ?? []
        // Drop any unknown raw values; fall back to the default layout if empty.
        let validTiles = storedTiles.filter { MetricKind(rawValue: $0) != nil }
        metricTiles = validTiles.isEmpty ? MetricKind.defaultOrder.map(\.rawValue) : validTiles
        showTileUnits = defaults.bool(forKey: Keys.showTileUnits)
        crashDetectionEnabled = defaults.bool(forKey: Keys.crashDetectionEnabled)
        emergencyContactName = defaults.string(forKey: Keys.emergencyContactName) ?? ""
        emergencyContactPhone = defaults.string(forKey: Keys.emergencyContactPhone) ?? ""
        applyLanguage()
    }

    var wheelCircumferenceMeters: Double { wheelCircumferenceMM / 1000.0 }
}
