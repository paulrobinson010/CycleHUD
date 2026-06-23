import Foundation

/// Lightweight on-device logger with crash capture. Writes timestamped lines to
/// a file in Documents that can be shared from the Diagnostics screen, so a
/// crash on a ride can be inspected afterwards (iOS crash logs are awkward to
/// retrieve in the field).
final class AppLog {
    static let shared = AppLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.cyclehud.applog")

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("cyclehud.log")
    }

    // MARK: - Logging

    func log(_ message: String) {
        let line = "\(Self.timestamp())  \(message)\n"
        queue.async { self.appendSync(line) }
    }

    func contents() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "No log yet."
    }

    func clear() {
        queue.async { try? "".write(to: self.fileURL, atomically: true, encoding: .utf8) }
    }

    private func appendSync(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > 600_000 {                 // keep the file from growing forever
                try? handle.truncate(atOffset: 0)
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - Crash capture

    /// Written synchronously during a crash (no fancy formatting — must stay simple).
    private func appendCrash(_ text: String) {
        guard let data = ("\n‼️ " + text + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    func installCrashHandlers() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            AppLog.shared.appendCrash("EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n\(symbols)")
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                let symbols = Thread.callStackSymbols.joined(separator: "\n")
                AppLog.shared.appendCrash("SIGNAL \(s)\n\(symbols)")
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
