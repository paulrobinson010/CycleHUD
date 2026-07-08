import Foundation
import Combine
import UIKit

/// Mirrors the app's data files (ride history, routes + ghosts) into the
/// app's own iCloud Drive container, so everything survives a lost phone and
/// follows the rider to a new one. No accounts and no CycleHUD server — the
/// data goes only into the user's own iCloud, and only while the Settings
/// toggle is on.
///
/// Sync model: each store serialises a payload of items plus deletion
/// tombstones. Pushes happen on every local save; pulls run at launch and on
/// every return to the foreground, and each store merges pulled items with
/// its own (per-item newest-wins; route ghosts keep the FASTER best, so two
/// phones race each other honestly). Requires the iCloud Documents capability
/// on the app target (see docs/SETUP.md); silently inactive when iCloud is
/// off or not signed in.
final class CloudSync: ObservableObject {

    /// True when the iCloud container is reachable (signed in, capability on).
    @Published private(set) var available = false

    /// Supplied by the app: the Settings toggle.
    var isEnabled: (() -> Bool)?
    /// Stores register their pull-and-merge here; runs at launch + foreground.
    var onSync: [() -> Void] = []

    private var containerURL: URL?
    private let queue = DispatchQueue(label: "cyclehud.cloudsync", qos: .utility)
    private var observer: NSObjectProtocol?

    /// Resolve the container (slow first call — off the main thread) and
    /// begin syncing on activation.
    func start() {
        queue.async { [weak self] in
            let url = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
            if let url {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.containerURL = url
                self.available = url != nil
                self.runSync()
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.runSync() }
    }

    private func runSync() {
        guard available, isEnabled?() ?? false else { return }
        onSync.forEach { $0() }
    }

    /// Write a payload into the container (iCloud uploads it in its own time).
    func push(_ data: Data, file: String) {
        guard available, isEnabled?() ?? false, let dir = containerURL else { return }
        queue.async {
            try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
        }
    }

    /// Read a payload from the container. If iCloud hasn't materialised the
    /// file locally yet (fresh install on a new phone), request the download
    /// and return nil — the next foreground sync picks it up.
    func pull(file: String) -> Data? {
        guard available, isEnabled?() ?? false, let dir = containerURL else { return nil }
        let url = dir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
