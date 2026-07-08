import Foundation
import Combine

/// Persists completed ride summaries to a local JSON file, newest first, so the
/// rider can review previous rides independently of Apple Health. With iCloud
/// sync on, the same list mirrors into the rider's own iCloud (union merge by
/// ride id with deletion tombstones), so history survives a lost phone.
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
        deletedIDs = deletedIDs + offsets.map { rides[$0].id }
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
        pushToCloud()
    }

    // MARK: - iCloud sync

    /// Wired in by the app; nil = sync off.
    var cloud: CloudSync?

    /// Deleted ride ids (tombstones) so a deletion on one phone doesn't get
    /// resurrected by a merge from another. Bounded.
    private var deletedIDs: [UUID] {
        get { (UserDefaults.standard.stringArray(forKey: "deletedRideIDs") ?? [])
                .compactMap(UUID.init) }
        set { UserDefaults.standard.set(newValue.suffix(300).map(\.uuidString),
                                        forKey: "deletedRideIDs") }
    }

    private struct CloudPayload: Codable {
        var rides: [RideSummary]
        var deleted: [UUID]
    }

    private func pushToCloud() {
        guard let cloud else { return }
        let payload = CloudPayload(rides: rides, deleted: deletedIDs)
        if let data = try? JSONEncoder().encode(payload) {
            cloud.push(data, file: "rides.json")
        }
    }

    /// Union-merge the cloud copy into this device (rides are immutable, so
    /// merging is: everything from both sides, minus deletions, newest first).
    func syncFromCloud() {
        guard let cloud else { return }
        guard let data = cloud.pull(file: "rides.json"),
              let payload = try? JSONDecoder().decode(CloudPayload.self, from: data) else {
            pushToCloud()          // nothing in the cloud yet — seed it
            return
        }
        let deleted = Set(deletedIDs).union(payload.deleted)
        deletedIDs = Array(deleted)

        var byID = Dictionary(uniqueKeysWithValues: rides.map { ($0.id, $0) })
        for remote in payload.rides where !deleted.contains(remote.id) {
            byID[remote.id] = byID[remote.id] ?? remote
        }
        var merged = byID.values.filter { !deleted.contains($0.id) }
            .sorted { $0.date > $1.date }
        if merged.count > maxRides { merged.removeLast(merged.count - maxRides) }
        if merged != rides {
            rides = merged
            if let data = try? JSONEncoder().encode(rides) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        pushToCloud()
    }
}
