import Foundation
import Combine

/// User-configurable settings, persisted to UserDefaults.
final class AppSettings: ObservableObject {

    private enum Keys {
        static let speedUnit = "speedUnit"
        static let distanceUnit = "distanceUnit"
        static let wheelCircumferenceMM = "wheelCircumferenceMM"
        static let beepEnabled = "beepEnabled"
        static let autoPauseEnabled = "autoPauseEnabled"
        static let keepScreenOn = "keepScreenOn"
        static let hasChosenUnits = "hasChosenUnits"
    }

    private let defaults = UserDefaults.standard

    @Published var speedUnit: SpeedUnit { didSet { defaults.set(speedUnit.rawValue, forKey: Keys.speedUnit) } }
    @Published var distanceUnit: DistanceUnit { didSet { defaults.set(distanceUnit.rawValue, forKey: Keys.distanceUnit) } }
    @Published var wheelCircumferenceMM: Double { didSet { defaults.set(wheelCircumferenceMM, forKey: Keys.wheelCircumferenceMM) } }
    @Published var beepEnabled: Bool { didSet { defaults.set(beepEnabled, forKey: Keys.beepEnabled) } }
    @Published var autoPauseEnabled: Bool { didSet { defaults.set(autoPauseEnabled, forKey: Keys.autoPauseEnabled) } }
    @Published var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: Keys.keepScreenOn) } }
    @Published var hasChosenUnits: Bool { didSet { defaults.set(hasChosenUnits, forKey: Keys.hasChosenUnits) } }

    init() {
        defaults.register(defaults: [
            Keys.speedUnit: SpeedUnit.kmh.rawValue,
            Keys.distanceUnit: DistanceUnit.km.rawValue,
            Keys.wheelCircumferenceMM: 2105.0,   // 700x25c default
            Keys.beepEnabled: true,
            Keys.autoPauseEnabled: true,
            Keys.keepScreenOn: true,
            Keys.hasChosenUnits: false
        ])

        speedUnit = SpeedUnit(rawValue: defaults.string(forKey: Keys.speedUnit) ?? "") ?? .kmh
        distanceUnit = DistanceUnit(rawValue: defaults.string(forKey: Keys.distanceUnit) ?? "") ?? .km
        wheelCircumferenceMM = defaults.double(forKey: Keys.wheelCircumferenceMM)
        beepEnabled = defaults.bool(forKey: Keys.beepEnabled)
        autoPauseEnabled = defaults.bool(forKey: Keys.autoPauseEnabled)
        keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        hasChosenUnits = defaults.bool(forKey: Keys.hasChosenUnits)
    }

    var wheelCircumferenceMeters: Double { wheelCircumferenceMM / 1000.0 }
}
