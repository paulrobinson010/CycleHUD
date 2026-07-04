import Foundation

/// One swipeable page of the ride screen: its tiles (in order), how many of
/// the leading tiles sit above the radar, and whether the radar lane is shown
/// at all — a data-only page hides it and lets the tiles stretch. Pages are
/// managed from the ride screen's tile-edit mode and persisted as JSON.
struct RidePage: Codable, Equatable, Identifiable {
    var id = UUID()
    var tiles: [String]            // MetricKind raw values, in order
    var topTileCount: Int = 0      // leading tiles above the radar (portrait)
    var showsRadar: Bool = true

    /// The default first page: the original layout, radar shown.
    static var standard: RidePage {
        RidePage(tiles: MetricKind.defaultOrder.map(\.rawValue))
    }
}
