import Foundation
import ObjectiveC

private var langSubKey: UInt8 = 0

/// A `Bundle` whose localized-string lookups redirect to the in-app language
/// override's `.lproj`. Both SwiftUI `Text` and Foundation `String(localized:)`
/// resolve through `Bundle.localizedString(forKey:value:table:)`, so swapping
/// `Bundle.main`'s class to this lets the whole UI change language live, without
/// an app relaunch. App Store-safe (no private API — just `object_setClass`).
private final class LocalizedBundle: Bundle, @unchecked Sendable {
    nonisolated override func localizedString(forKey key: String, value: String?,
                                              table tableName: String?) -> String {
        if let sub = objc_getAssociatedObject(self, &langSubKey) as? Bundle {
            return sub.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

enum Lang {
    /// The chosen language's bundle (or `.main` for the device language). Pass it
    /// to `String(localized:bundle:)` where a guaranteed live switch is needed.
    private(set) static var bundle: Bundle = .main

    /// Point every localized lookup at `code` (a BCP-47 code like "de-DE"), or at
    /// the device's own language when `code` is empty.
    static func apply(_ code: String) {
        if !(Bundle.main is LocalizedBundle) {
            object_setClass(Bundle.main, LocalizedBundle.self)
        }
        var sub: Bundle?
        if !code.isEmpty {
            // Try the exact code, then the language part (e.g. "de-DE" → "de").
            for resource in [code, String(code.prefix(2))] {
                if let path = Bundle.main.path(forResource: resource, ofType: "lproj"),
                   let b = Bundle(path: path) {
                    sub = b
                    break
                }
            }
        }
        bundle = sub ?? .main
        objc_setAssociatedObject(Bundle.main, &langSubKey, sub, .OBJC_ASSOCIATION_RETAIN)
    }
}
