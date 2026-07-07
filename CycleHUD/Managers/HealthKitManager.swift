import Foundation
import HealthKit
import CoreLocation

/// Reads body metrics (for calorie estimation) and writes a cycling workout —
/// distance, calories and GPS route — to Apple Health when a ride stops.
///
/// All API calls compile without the HealthKit entitlement; they simply no-op /
/// fail authorization at runtime until the HealthKit capability is enabled on
/// the target in Xcode.
final class HealthKitManager: ObservableObject {

    let store = HKHealthStore()
    @Published private(set) var authorized = false

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() {
        guard isAvailable else { return }
        var share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceCycling)
        ]
        if #available(iOS 18.0, *) {
            share.insert(HKQuantityType(.workoutEffortScore))
        }
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.bodyMass),
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex)
        ]
        store.requestAuthorization(toShare: share, read: read) { [weak self] ok, _ in
            DispatchQueue.main.async { self?.authorized = ok }
        }
    }

    // MARK: - Body metrics

    func ageYears() -> Double? {
        guard let dob = try? store.dateOfBirthComponents(),
              let y = dob.year, let m = dob.month, let d = dob.day,
              let birth = Calendar.current.date(from: DateComponents(year: y, month: m, day: d)),
              let years = Calendar.current.dateComponents([.year], from: birth, to: Date()).year
        else { return nil }
        return Double(years)
    }

    func isFemale() -> Bool? {
        guard let sex = try? store.biologicalSex().biologicalSex else { return nil }
        switch sex {
        case .female: return true
        case .male: return false
        default: return nil
        }
    }

    func latestWeightKg() async -> Double? {
        await withCheckedContinuation { continuation in
            let type = HKQuantityType(.bodyMass)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: [sort]) { _, samples, _ in
                let kg = (samples?.first as? HKQuantitySample)?
                    .quantity.doubleValue(for: .gramUnit(with: .kilo))
                continuation.resume(returning: kg)
            }
            store.execute(query)
        }
    }

    // MARK: - Workout effort score (iOS 18+)

    /// Whether Apple's 1–10 workout effort score can be recorded on this OS.
    var supportsEffortScore: Bool {
        if #available(iOS 18.0, *) { return isAvailable } else { return false }
    }

    /// The workout written by the most recent `saveRide`, kept so an effort
    /// score picked on the end-of-ride summary can be related to it.
    private var lastSavedWorkout: HKWorkout?
    /// Effort picked before the async workout save finished; applied on completion.
    private var pendingEffortScore: Int?
    /// The effort sample we wrote, replaced if the rider revises their pick.
    private var lastEffortSample: HKSample?
    /// Serialises effort writes so a quick re-tap can't race the delete+save.
    private var effortTask: Task<Void, Never>?

    /// Record the rider's 1–10 perceived effort against the workout just saved.
    /// Safe to call before the save finishes — the score is applied when it does.
    /// Calling again replaces the previous score.
    func recordEffort(score: Int) {
        guard #available(iOS 18.0, *), (1...10).contains(score) else { return }
        pendingEffortScore = score
        guard let workout = lastSavedWorkout else { return }   // applied post-save
        effortTask = Task { [previous = effortTask] in
            await previous?.value
            await self.applyEffort(score, to: workout)
        }
    }

    @available(iOS 18.0, *)
    private func applyEffort(_ score: Int, to workout: HKWorkout) async {
        let quantity = HKQuantity(unit: .appleEffortScore(), doubleValue: Double(score))
        let sample = HKQuantitySample(type: HKQuantityType(.workoutEffortScore),
                                      quantity: quantity,
                                      start: workout.startDate, end: workout.endDate)
        if let old = lastEffortSample {
            _ = try? await store.unrelateWorkoutEffortSample(old, from: workout, activity: nil)
            try? await store.delete(old)
        }
        do {
            _ = try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
            await MainActor.run { lastEffortSample = sample }
        } catch {
            // Non-fatal: the workout simply has no effort score.
        }
    }

    // MARK: - Saving a workout

    func saveRide(start: Date, end: Date, distanceMeters: Double,
                  calories: Double, route: [CLLocation]) async {
        guard isAvailable, end > start else { return }
        await MainActor.run {
            lastSavedWorkout = nil
            pendingEffortScore = nil
            lastEffortSample = nil
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)

            var samples: [HKSample] = []
            if calories > 0 {
                let energy = HKQuantity(unit: .kilocalorie(), doubleValue: calories)
                samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                                 quantity: energy, start: start, end: end))
            }
            if distanceMeters > 0 {
                let distance = HKQuantity(unit: .meter(), doubleValue: distanceMeters)
                samples.append(HKQuantitySample(type: HKQuantityType(.distanceCycling),
                                                 quantity: distance, start: start, end: end))
            }
            if !samples.isEmpty { try await builder.addSamples(samples) }

            try await builder.endCollection(at: end)
            let workout = try await builder.finishWorkout()

            // Attach the GPS route if we have one.
            if let workout, route.count > 1 {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                try await routeBuilder.insertRouteData(route)
                try await routeBuilder.finishRoute(with: workout, metadata: nil)
            }

            // Publish the workout for the effort prompt, and apply a score the
            // rider picked while this save was still in flight.
            if let workout {
                let pending: Int? = await MainActor.run {
                    lastSavedWorkout = workout
                    return pendingEffortScore
                }
                if #available(iOS 18.0, *), let pending {
                    await applyEffort(pending, to: workout)
                }
            }
        } catch {
            // Non-fatal: the ride simply isn't saved (e.g. authorization denied).
        }
    }
}
