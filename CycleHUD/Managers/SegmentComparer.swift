import Foundation
import CoreLocation

/// A macro-level comparison: one stretch of the current ride against the best
/// previous time over that same stretch of road.
struct SegmentComparison: Identifiable, Equatable {
    let id = UUID()
    let startMeters: Double          // along the current ride
    let endMeters: Double
    let currentSeconds: Double
    let bestSeconds: Double          // best among previous rides covering it
    let bestDate: Date               // when that best was set

    var lengthMeters: Double { endMeters - startMeters }
    var deltaSeconds: Double { currentSeconds - bestSeconds }
    var isFastest: Bool { deltaSeconds < 0 }
}

/// Finds where the current ride re-rode roads from previous rides and compares
/// times — granular matching, macro display.
///
/// Matching is point-based: a stretch of the current route "matches" a previous
/// ride where its points run close to that ride's points (within ~30 m), in the
/// same direction, progressing monotonically. Each such overlap becomes a *run*
/// carrying the previous ride's clock along the current ride's distance axis.
///
/// Display is macro: the ride is split only where the SET of covering previous
/// rides changes (a past ride turned off here), never on sub-kilometre
/// fragments. Each region is compared against the best previous time over that
/// whole region — so riding a 10 km road that one past ride covered fully and
/// another left at 6 km yields exactly two comparisons: 0–6 km (best of both)
/// and 6–10 km (the full-length ride only).
enum SegmentComparer {

    // Tunables
    private static let matchRadius = 30.0         // m — same-road tolerance
    private static let headingTolerance = 60.0    // deg — same direction
    private static let maxIndexJump = 8           // prev points skippable in a run
    private static let gapTolerance = 2           // unmatched current points bridged
    private static let minRunMeters = 500.0       // ignore shorter overlaps
    private static let minRegionMeters = 1000.0   // macro display floor
    private static let boundarySlack = 150.0      // coverage slack at region edges
    private static let boundaryMerge = 200.0      // boundaries closer than this merge

    // MARK: - Public

    /// Compare `current` against strictly earlier rides. Pure and synchronous —
    /// call it off the main thread for big histories.
    static func compare(_ current: RideSummary,
                        against history: [RideSummary]) -> [SegmentComparison] {
        guard let cur = path(of: current) else { return [] }
        var runs: [Run] = []
        for prev in history where prev.id != current.id && prev.date < current.date {
            guard let pp = path(of: prev) else { continue }
            runs += matchRuns(current: cur, previous: pp, prevDate: prev.date)
        }
        guard !runs.isEmpty else { return [] }
        return regions(cur: cur, runs: runs)
    }

    // MARK: - Paths

    /// A ride's stored route as a comparable path: cumulative distance, an
    /// estimated clock at every point, and per-segment headings.
    private struct Path {
        let coords: [CLLocationCoordinate2D]
        let dist: [Double]
        let time: [Double]
        let heading: [Double]
    }

    private static func path(of summary: RideSummary) -> Path? {
        let coords = summary.coordinates
        guard coords.count >= 2, summary.movingTimeSeconds > 0 else { return nil }

        var dist = [0.0]
        dist.reserveCapacity(coords.count)
        for i in 1..<coords.count {
            dist.append(dist[i - 1] + meters(coords[i - 1], coords[i]))
        }
        guard let total = dist.last, total > 0 else { return nil }

        // Clock estimate: integrate per-point speeds when stored (then normalise
        // to the ride's moving time); else uniform — route fixes arrive at a
        // steady rate and were downsampled uniformly, so index ≈ time.
        var time: [Double]
        if let speeds = summary.routeSpeeds, speeds.count == coords.count {
            time = [0.0]
            for i in 1..<coords.count {
                let v = max(0.5, (speeds[i - 1] + speeds[i]) / 2)
                time.append(time[i - 1] + (dist[i] - dist[i - 1]) / v)
            }
            if let t = time.last, t > 0 {
                let scale = summary.movingTimeSeconds / t
                time = time.map { $0 * scale }
            }
        } else {
            let n = Double(coords.count - 1)
            time = (0..<coords.count).map { summary.movingTimeSeconds * Double($0) / n }
        }

        var heading = [Double]()
        heading.reserveCapacity(coords.count)
        for i in 0..<coords.count - 1 {
            heading.append(bearing(coords[i], coords[i + 1]))
        }
        heading.append(heading.last ?? 0)

        return Path(coords: coords, dist: dist, time: time, heading: heading)
    }

    // MARK: - Matching

    /// The previous ride's clock carried along the current ride's distance axis,
    /// over one contiguous overlap.
    private struct Run {
        let curD: [Double]
        let prevT: [Double]
        let prevDate: Date
        var start: Double { curD.first ?? 0 }
        var end: Double { curD.last ?? 0 }
        func prevTime(at d: Double) -> Double { interp(curD, prevT, d) }
    }

    private static func matchRuns(current: Path, previous: Path,
                                  prevDate: Date) -> [Run] {
        // Spatial hash of the previous ride's points, cell ≈ match radius.
        let midLat = previous.coords[previous.coords.count / 2].latitude
        let latCell = matchRadius / 111_320.0
        let lonCell = matchRadius / max(1.0, 111_320.0 * cos(midLat * .pi / 180))
        var grid: [Int64: [Int]] = [:]
        func key(_ c: CLLocationCoordinate2D) -> (Int64, Int64) {
            (Int64((c.latitude / latCell).rounded(.down)),
             Int64((c.longitude / lonCell).rounded(.down)))
        }
        func packed(_ a: Int64, _ b: Int64) -> Int64 { a &* 1_000_003 &+ b }
        for (j, c) in previous.coords.enumerated() {
            let (a, b) = key(c)
            grid[packed(a, b), default: []].append(j)
        }

        var runs: [Run] = []
        var runD: [Double] = []
        var runT: [Double] = []
        var lastJ = -1
        var gap = 0

        func closeRun() {
            if let a = runD.first, let b = runD.last, b - a >= minRunMeters {
                runs.append(Run(curD: runD, prevT: runT, prevDate: prevDate))
            }
            runD = []; runT = []
            lastJ = -1; gap = 0
        }

        for i in 0..<current.coords.count {
            let c = current.coords[i]
            let (a, b) = key(c)
            var bestJ = -1
            var bestDist = matchRadius
            for da in -1...1 {
                for db in -1...1 {
                    for j in grid[packed(a + Int64(da), b + Int64(db))] ?? [] {
                        // Monotonic progression along the previous ride.
                        if lastJ >= 0, j < lastJ - 1 || j > lastJ + maxIndexJump { continue }
                        let d = meters(c, previous.coords[j])
                        guard d <= bestDist else { continue }
                        // Same direction of travel.
                        var diff = abs(current.heading[i] - previous.heading[j])
                        if diff > 180 { diff = 360 - diff }
                        guard diff <= headingTolerance else { continue }
                        bestDist = d
                        bestJ = j
                    }
                }
            }
            if bestJ >= 0 {
                runD.append(current.dist[i])
                runT.append(previous.time[bestJ])
                lastJ = max(lastJ, bestJ)
                gap = 0
            } else if !runD.isEmpty {
                gap += 1
                if gap > gapTolerance { closeRun() }
            }
        }
        closeRun()
        return runs
    }

    // MARK: - Macro regions

    private static func regions(cur: Path, runs: [Run]) -> [SegmentComparison] {
        // Boundaries where any past ride joined or left the current route.
        var boundaries = runs.flatMap { [$0.start, $0.end] }.sorted()
        var merged: [Double] = []
        for b in boundaries where merged.last.map({ b - $0 > boundaryMerge }) ?? true {
            merged.append(b)
        }
        boundaries = merged
        guard boundaries.count >= 2 else { return [] }

        struct Region { var a: Double; var b: Double; var covering: Set<Int> }
        var regionList: [Region] = []
        for i in 0..<boundaries.count - 1 {
            let a = boundaries[i], b = boundaries[i + 1]
            let covering = Set(runs.indices.filter {
                runs[$0].start <= a + boundarySlack && runs[$0].end >= b - boundarySlack
            })
            guard !covering.isEmpty else { continue }
            // Same covering set as the neighbour → one macro region, not two
            // (this is what stops sub-stretch fragments splitting the view).
            if var last = regionList.last, last.covering == covering, last.b >= a - boundaryMerge {
                last.b = b
                regionList[regionList.count - 1] = last
            } else {
                regionList.append(Region(a: a, b: b, covering: covering))
            }
        }

        return regionList.compactMap { r in
            guard r.b - r.a >= minRegionMeters else { return nil }
            let currentTime = interp(cur.dist, cur.time, r.b) - interp(cur.dist, cur.time, r.a)
            var best = Double.greatestFiniteMagnitude
            var bestDate = Date.distantPast
            for idx in r.covering {
                let t = runs[idx].prevTime(at: r.b) - runs[idx].prevTime(at: r.a)
                if t > 0, t < best { best = t; bestDate = runs[idx].prevDate }
            }
            guard currentTime > 0, best < .greatestFiniteMagnitude else { return nil }
            return SegmentComparison(startMeters: r.a, endMeters: r.b,
                                     currentSeconds: currentTime,
                                     bestSeconds: best, bestDate: bestDate)
        }
    }

    // MARK: - Geometry helpers

    private static func meters(_ a: CLLocationCoordinate2D,
                               _ b: CLLocationCoordinate2D) -> Double {
        // Flat-earth approximation — plenty at ride scale, and much faster
        // than CLLocation.distance for the hot loop.
        let dLat = (b.latitude - a.latitude) * 111_320.0
        let dLon = (b.longitude - a.longitude) * 111_320.0
            * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    private static func bearing(_ a: CLLocationCoordinate2D,
                                _ b: CLLocationCoordinate2D) -> Double {
        let dLat = b.latitude - a.latitude
        let dLon = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
        let deg = atan2(dLon, dLat) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
}

/// Linear interpolation of `ys` over monotonically increasing `xs`.
private func interp(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
    guard let first = xs.first, let last = xs.last, xs.count == ys.count else { return 0 }
    if x <= first { return ys[0] }
    if x >= last { return ys[ys.count - 1] }
    var lo = 0, hi = xs.count - 1
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if xs[mid] <= x { lo = mid } else { hi = mid }
    }
    let span = xs[hi] - xs[lo]
    let w = span > 0 ? (x - xs[lo]) / span : 0
    return ys[lo] + (ys[hi] - ys[lo]) * w
}
