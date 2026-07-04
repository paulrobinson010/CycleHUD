import Foundation
import CoreLocation
import Combine
#if canImport(WeatherKit)
import WeatherKit
#endif

/// Fetches a short-term rain nowcast from Apple WeatherKit for the current
/// location and publishes a distilled `RainNowcast` for the UI. Throttled and
/// fail-soft: country lanes have patchy signal, so any error simply leaves the
/// last good value (or nothing) rather than disrupting the ride.
///
/// Requires the **WeatherKit** capability/service on the App ID (see
/// docs/SETUP.md). Apple also requires the data to be **attributed** wherever
/// it's shown — see `WeatherAttributionView`.
@MainActor
final class WeatherManager: ObservableObject {

    enum Status: Equatable { case idle, loading, ready, unavailable }

    @Published private(set) var nowcast: RainNowcast?
    /// Current temperature and wind for the ride tiles (nil until first fetch).
    @Published private(set) var conditions: WeatherConditions?
    @Published private(set) var status: Status = .idle
    /// Human-readable last error / state, surfaced in Diagnostics for debugging.
    @Published private(set) var lastErrorText: String?
    @Published private(set) var lastUpdated: Date?

    /// Supplied by the app: the current coordinate and whether weather is enabled.
    var locationProvider: (() -> CLLocation?)?
    var isEnabled: (() -> Bool)?

    private var lastFetch: Date?
    /// Minimum gap between network fetches. Just below the 60 s tick so each tick
    /// actually refreshes (the nowcast — and its "rain in N min" countdown — is
    /// only as current as the last fetch, so we refresh every minute while shown).
    private let minInterval: TimeInterval = 45
    private var timer: Timer?

    /// Begin minute-by-minute refreshes (idempotent). WeatherKit's minute forecast
    /// is designed for exactly this polling, and it keeps the countdown live.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    #if canImport(WeatherKit)
    private let service = WeatherService.shared
    #endif

    /// Refresh if enabled, located, and the throttle has elapsed (or forced).
    func refresh(force: Bool = false) async {
        guard isEnabled?() ?? false else {
            nowcast = nil; conditions = nil; status = .idle; lastErrorText = nil; return
        }
        guard let loc = locationProvider?() else {
            lastErrorText = "Waiting for a location fix…"   // can't fetch without a coordinate
            return
        }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < minInterval { return }

        #if canImport(WeatherKit)
        status = nowcast == nil ? .loading : status
        do {
            let (rain, current) = try await fetchWeather(for: loc)
            lastFetch = Date()
            lastUpdated = Date()
            lastErrorText = nil
            nowcast = rain
            conditions = current
            status = .ready
        } catch {
            // Leave the last good value; only flag unavailable if we have nothing.
            if nowcast == nil { status = .unavailable }
            lastErrorText = error.localizedDescription
            AppLog.shared.log("Weather fetch failed: \(error.localizedDescription)")
        }
        #else
        status = .unavailable
        lastErrorText = "WeatherKit not available in this build."
        #endif
    }

    #if canImport(WeatherKit)
    // MARK: - WeatherKit → RainNowcast

    private func fetchWeather(for location: CLLocation) async throws
        -> (RainNowcast, WeatherConditions) {
        let weather = try await service.weather(for: location)
        let now = Date()
        let rain: RainNowcast
        if let minute = weather.minuteForecast, !minute.isEmpty {
            rain = Self.fromMinute(Array(minute), now: now)
        } else {
            rain = Self.fromHourly(Array(weather.hourlyForecast), now: now)
        }
        let cur = weather.currentWeather
        let conditions = WeatherConditions(
            temperatureC: cur.temperature.converted(to: .celsius).value,
            windSpeedMps: cur.wind.speed.converted(to: .metersPerSecond).value,
            gustMps: cur.wind.gust?.converted(to: .metersPerSecond).value,
            windFromDegrees: cur.wind.direction.converted(to: .degrees).value,
            asOf: now)
        return (rain, conditions)
    }

    /// Minute-by-minute path (best). A minute counts as "wet" when the chance of
    /// precipitation is meaningful; onset/duration come from the contiguous run.
    static func fromMinute(_ minutes: [MinuteWeather], now: Date) -> RainNowcast {
        let wetChance = 0.35
        func wet(_ m: MinuteWeather) -> Bool { m.precipitationChance >= wetChance }

        let isRaining = minutes.first.map(wet) ?? false
        var startIdx: Int? = nil
        if !isRaining { startIdx = minutes.firstIndex(where: wet) }

        // The contiguous wet run from the onset (or from now if already raining).
        let runStart = isRaining ? 0 : (startIdx ?? 0)
        var runEnd = runStart
        if startIdx != nil || isRaining {
            runEnd = runStart
            while runEnd < minutes.count, wet(minutes[runEnd]) { runEnd += 1 }
        }
        let durationMin = (startIdx != nil || isRaining) ? max(1, runEnd - runStart) : nil
        let openEnded = runEnd >= minutes.count   // rain continues past the window
        let peakMM = minutes[runStart..<max(runStart + 1, runEnd)]
            .map { mmPerHour($0.precipitationIntensity) }.max() ?? 0

        return RainNowcast(
            isRaining: isRaining,
            startsInMinutes: isRaining ? nil : startIdx.map { minuteOffset(minutes[$0].date, from: now) },
            durationMinutes: openEnded ? nil : durationMin,
            peak: .from(mmPerHour: peakMM),
            usedMinuteData: true,
            asOf: now)
    }

    /// Coarse hourly fallback for regions without minute data: look a few hours
    /// out, report the first wet hour and how many contiguous wet hours follow.
    static func fromHourly(_ hours: [HourWeather], now: Date) -> RainNowcast {
        let window = hours.filter { $0.date >= now.addingTimeInterval(-3600) }.prefix(4)
        let arr = Array(window)
        func wet(_ h: HourWeather) -> Bool { h.precipitationChance >= 0.4 }

        let isRaining = arr.first.map { wet($0) && $0.date <= now } ?? false
        let startIdx = arr.firstIndex(where: { wet($0) && $0.date > now })
        var peakMM = 0.0
        var wetHours = 0
        if let s = isRaining ? 0 : startIdx {
            var i = s
            while i < arr.count, wet(arr[i]) {
                peakMM = max(peakMM, arr[i].precipitationAmount.converted(to: .millimeters).value)
                wetHours += 1; i += 1
            }
        }
        return RainNowcast(
            isRaining: isRaining,
            startsInMinutes: isRaining ? nil : startIdx.map { minuteOffset(arr[$0].date, from: now) },
            durationMinutes: wetHours > 0 ? wetHours * 60 : nil,
            peak: .from(mmPerHour: peakMM),       // amount over an hour ≈ mm/hr
            usedMinuteData: false,
            asOf: now)
    }

    private static func minuteOffset(_ date: Date, from now: Date) -> Int {
        max(0, Int((date.timeIntervalSince(now) / 60).rounded()))
    }

    /// WeatherKit reports precipitation intensity as a rate; convert to mm/hr.
    /// (Isolated here because the exact unit is the one thing worth verifying on
    /// a real device — if values look off, adjust this single function.)
    private static func mmPerHour(_ m: Measurement<UnitSpeed>) -> Double {
        // UnitSpeed's base unit is m/s; 1 mm/hr = 1/3_600_000 m/s.
        m.converted(to: .metersPerSecond).value * 3_600_000
    }
    #endif
}
