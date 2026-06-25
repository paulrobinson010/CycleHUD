import Foundation
import Combine

/// Persists completed ride summaries to a local JSON file, newest first, so the
/// rider can review previous rides independently of Apple Health.
final class RideHistory: ObservableObject {
    @Published private(set) var rides: [RideSummary] = []

    private let maxRides = 500
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("rideHistory.json")
    }()

    init() { load() }

    func add(_ summary: RideSummary) {
        rides.insert(summary, at: 0)               // newest first
        if rides.count > maxRides { rides.removeLast(rides.count - maxRides) }
        save()
    }

    func delete(at offsets: IndexSet) {
        rides.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RideSummary].self, from: data) else { return }
        rides = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rides) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
