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
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceCycling)
        ]
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

    // MARK: - Saving a workout

    func saveRide(start: Date, end: Date, distanceMeters: Double,
                  calories: Double, route: [CLLocation]) async {
        guard isAvailable, end > start else { return }

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
        } catch {
            // Non-fatal: the ride simply isn't saved (e.g. authorization denied).
        }
    }
}
