import Foundation
import CloudKit
import CoreLocation

/// Live tracking without accounts or servers: while riding, the phone
/// publishes position + headline stats to a CloudKit *public* database
/// record named by a random token, and anyone with the share link watches
/// it on the website (docs/live.html reads the record via CloudKit's REST
/// lookup). Ending the ride deletes the record, so the link goes dead —
/// nothing about the ride stays published.
final class LiveTrackManager: ObservableObject {

    enum State: Equatable {
        case off
        case live       // session active, records being pushed
        case failed     // last save failed (iCloud off / no signal); keeps retrying
    }

    @Published private(set) var state: State = .off
    @Published private(set) var shareURL: URL?

    /// Wired to the Settings toggle by the app.
    var isEnabled: (() -> Bool)?

    private let database = CKContainer.default().publicCloudDatabase
    private var record: CKRecord?
    private var lastPush = Date.distantPast
    private let pushInterval: TimeInterval = 15
    /// The path ridden so far, appended one point per push and thinned when
    /// it grows past ~400 points — a few KB encoded, well inside record limits.
    private var trail: [(Double, Double)] = []
    /// The planned route's path (when one was active at ride start), encoded
    /// once so watchers see where the ride is headed.
    private var routeEncoded: String?

    func beginSession(routePath: [(Double, Double)]? = nil) {
        guard isEnabled?() ?? false, state == .off else { return }
        let token = Self.makeToken()
        record = CKRecord(recordType: "LiveRide",
                          recordID: CKRecord.ID(recordName: "live-\(token)"))
        shareURL = URL(string: "https://cyclehud.robbo-online.uk/live.html#\(token)")
        lastPush = .distantPast
        trail = []
        routeEncoded = routePath.map { Self.encode($0) }
        state = .live
        AppLog.shared.log("Live tracking session started")
    }

    /// Push the rider's position and stats; throttled to one save per 15 s.
    func update(location: CLLocation?, distanceMeters: Double, speedMps: Double,
                movingSeconds: Double, paused: Bool,
                remainingMeters: Double? = nil, etaSeconds: Double? = nil) {
        guard let record, let location else { return }
        guard Date().timeIntervalSince(lastPush) >= pushInterval else { return }
        lastPush = Date()
        trail.append((location.coordinate.latitude, location.coordinate.longitude))
        if trail.count > 400 {
            trail = trail.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element : nil }
        }
        record["lat"] = location.coordinate.latitude
        record["lon"] = location.coordinate.longitude
        record["speedMps"] = speedMps
        record["distanceMeters"] = distanceMeters
        record["movingSeconds"] = movingSeconds
        record["paused"] = paused ? 1 : 0
        record["trail"] = Self.encode(trail)
        record["route"] = routeEncoded
        record["remainingMeters"] = remainingMeters
        record["etaSeconds"] = etaSeconds
        record["updatedAt"] = Date()
        database.save(record) { [weak self] saved, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let saved, error == nil {
                    self.record = saved       // carry the server change tag forward
                    if self.state == .failed { self.state = .live }
                } else if self.state == .live {
                    self.state = .failed
                    AppLog.shared.log("Live tracking save failed: \(error?.localizedDescription ?? "?")")
                }
            }
        }
    }

    /// Delete the published record — the share link goes dead immediately.
    func endSession() {
        guard let record else { return }
        self.record = nil
        state = .off
        shareURL = nil
        database.delete(withRecordID: record.recordID) { _, error in
            if let error {
                AppLog.shared.log("Live tracking cleanup failed: \(error.localizedDescription)")
            } else {
                AppLog.shared.log("Live tracking session ended")
            }
        }
    }

    /// "lat,lon;lat,lon;…" at 5 decimals (~1 m), thinned to ≤300 points —
    /// compact enough to live inside the record, trivial for the page to parse.
    private static func encode(_ path: [(Double, Double)]) -> String {
        var pts = path
        if pts.count > 300 {
            let stride = Double(pts.count - 1) / 299.0
            pts = (0..<300).map { path[Int((Double($0) * stride).rounded())] }
        }
        return pts.map { String(format: "%.5f,%.5f", $0.0, $0.1) }.joined(separator: ";")
    }

    /// 10 random base32 characters — unguessable enough for a transient link.
    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }
}
