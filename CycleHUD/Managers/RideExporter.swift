import Foundation
import CoreLocation

/// Builds GPX 1.1 and Garmin TCX documents from a finished ride so it can be
/// shared to other apps (Strava, Komoot, Ride with GPS, …) through the system
/// share sheet. Works from a `RideSummary` alone, so both the just-finished ride
/// and any entry in the history list can be exported.
///
/// The summary stores two parallel downsampled series — the GPS track
/// (lat/lon + per-point speed) and a metrics track (time / relative altitude /
/// heart rate) — neither of which carries an absolute per-point timestamp. We
/// reconstruct plausible trackpoint times by spreading the route across the
/// ride's moving time in proportion to the distance covered, and read elevation
/// and heart rate from the metrics track at the matching point in the ride. The
/// result is a standards-clean file good enough for Strava et al. to import
/// (they recompute most derived stats from position + time anyway).
enum RideExporter {

    enum Format: String {
        case gpx, tcx
        var fileExtension: String { rawValue }
    }

    // MARK: - Public API

    /// Write the ride to a temporary file and return its URL (for ShareLink / the
    /// share sheet). Returns nil if the ride has too little GPS to be worth
    /// exporting.
    static func writeTemporaryFile(for summary: RideSummary, format: Format) -> URL? {
        guard let text = string(for: summary, format: format) else { return nil }
        let name = "\(fileBaseName(for: summary)).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            AppLog.shared.log("Ride export write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether this ride has enough of a GPS track to export.
    static func canExport(_ summary: RideSummary) -> Bool {
        (summary.routePoints?.count ?? 0) >= 2
    }

    /// The serialised document, or nil if there's no usable track.
    static func string(for summary: RideSummary, format: Format) -> String? {
        let points = reconstructedPoints(for: summary)
        guard points.count >= 2 else { return nil }
        switch format {
        case .gpx: return gpx(points, summary: summary)
        case .tcx: return tcx(points, summary: summary)
        }
    }

    // MARK: - Trackpoint reconstruction

    /// A trackpoint built from the summary: position plus an interpolated
    /// timestamp, elevation profile and heart rate.
    private struct Point {
        let coord: Coord
        let time: Date
        let elevation: Double?   // metres; an elevation *profile* (base = ride start)
        let hr: Int?
        let speedMps: Double?
    }

    private static func reconstructedPoints(for summary: RideSummary) -> [Point] {
        let coords = summary.routePoints ?? []
        guard coords.count >= 2 else { return [] }
        let speeds = summary.routeSpeeds
        let track = summary.track ?? []
        let trackSpan = track.last?.t ?? 0

        // Cumulative ground distance along the route, to weight timestamps by how
        // far the rider had travelled (so stops/climbs aren't given equal time).
        var cumulative = [Double](repeating: 0, count: coords.count)
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i - 1].lat, longitude: coords[i - 1].lon)
            let b = CLLocation(latitude: coords[i].lat, longitude: coords[i].lon)
            cumulative[i] = cumulative[i - 1] + a.distance(from: b)
        }
        let total = cumulative.last ?? 0
        let duration = max(summary.movingTimeSeconds, 1)

        return coords.indices.map { i in
            // Fraction through the ride (by distance, or evenly if total is 0).
            let f = total > 0 ? cumulative[i] / total : Double(i) / Double(coords.count - 1)
            let time = summary.date.addingTimeInterval(f * duration)
            let sample = trackSpan > 0 ? interpolatedTrack(track, at: f * trackSpan) : nil
            let speed: Double? = {
                if let speeds, speeds.count == coords.count { return speeds[i] }
                return sample?.speedMps
            }()
            return Point(coord: coords[i], time: time,
                         elevation: sample?.altitude, hr: sample?.hr, speedMps: speed)
        }
    }

    /// Linearly interpolate the metrics track (altitude / heart rate / speed) at a
    /// time `t` seconds into the ride.
    private static func interpolatedTrack(_ track: [TrackSample], at t: Double)
        -> (altitude: Double, hr: Int?, speedMps: Double)? {
        guard !track.isEmpty else { return nil }
        if t <= track.first!.t { let s = track.first!; return (s.altitude, s.hr, s.speedMps) }
        if t >= track.last!.t { let s = track.last!; return (s.altitude, s.hr, s.speedMps) }
        for i in 1..<track.count where track[i].t >= t {
            let a = track[i - 1], b = track[i]
            let span = b.t - a.t
            let w = span > 0 ? (t - a.t) / span : 0
            let alt = a.altitude + (b.altitude - a.altitude) * w
            let spd = a.speedMps + (b.speedMps - a.speedMps) * w
            let hr = w < 0.5 ? a.hr : b.hr   // HR is discrete; take the nearer sample
            return (alt, hr, spd)
        }
        let s = track.last!
        return (s.altitude, s.hr, s.speedMps)
    }

    // MARK: - GPX 1.1

    private static func gpx(_ points: [Point], summary: RideSummary) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="CycleHUD"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escaped(rideName(for: summary)))</name>
            <time>\(iso(summary.date))</time>
          </metadata>
          <trk>
            <name>\(escaped(rideName(for: summary)))</name>
            <type>cycling</type>
            <trkseg>

        """
        for p in points {
            xml += "      <trkpt lat=\"\(coord(p.coord.lat))\" lon=\"\(coord(p.coord.lon))\">\n"
            if let ele = p.elevation { xml += "        <ele>\(num(ele, 1))</ele>\n" }
            xml += "        <time>\(iso(p.time))</time>\n"
            if let hr = p.hr, hr > 0 {
                xml += """
                        <extensions>
                          <gpxtpx:TrackPointExtension>
                            <gpxtpx:hr>\(hr)</gpxtpx:hr>
                          </gpxtpx:TrackPointExtension>
                        </extensions>

                """
            }
            xml += "      </trkpt>\n"
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }

    // MARK: - Garmin TCX

    private static func tcx(_ points: [Point], summary: RideSummary) -> String {
        let startISO = iso(summary.date)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase
            xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
            xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
          <Activities>
            <Activity Sport="Biking">
              <Id>\(startISO)</Id>
              <Lap StartTime="\(startISO)">
                <TotalTimeSeconds>\(num(summary.movingTimeSeconds, 0))</TotalTimeSeconds>
                <DistanceMeters>\(num(summary.distanceMeters, 1))</DistanceMeters>
                <Calories>\(Int(summary.caloriesKcal.rounded()))</Calories>

        """
        if let avg = summary.averageHeartRate, avg > 0 {
            xml += "            <AverageHeartRateBpm><Value>\(avg)</Value></AverageHeartRateBpm>\n"
        }
        if let mx = summary.maxHeartRate, mx > 0 {
            xml += "            <MaximumHeartRateBpm><Value>\(mx)</Value></MaximumHeartRateBpm>\n"
        }
        xml += """
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>

        """
        for p in points {
            xml += "          <Trackpoint>\n"
            xml += "            <Time>\(iso(p.time))</Time>\n"
            xml += "            <Position>\n"
            xml += "              <LatitudeDegrees>\(coord(p.coord.lat))</LatitudeDegrees>\n"
            xml += "              <LongitudeDegrees>\(coord(p.coord.lon))</LongitudeDegrees>\n"
            xml += "            </Position>\n"
            if let ele = p.elevation { xml += "            <AltitudeMeters>\(num(ele, 1))</AltitudeMeters>\n" }
            if let hr = p.hr, hr > 0 {
                xml += "            <HeartRateBpm><Value>\(hr)</Value></HeartRateBpm>\n"
            }
            if let spd = p.speedMps {
                xml += """
                            <Extensions>
                              <ns3:TPX>
                                <ns3:Speed>\(num(spd, 2))</ns3:Speed>
                              </ns3:TPX>
                            </Extensions>

                """
            }
            xml += "          </Trackpoint>\n"
        }
        xml += """
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """
        return xml
    }

    // MARK: - Formatting helpers (locale-independent on purpose)

    /// ISO-8601 UTC, e.g. 2026-06-30T08:15:00Z. Built once and reused.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// Fixed-point number with a '.' decimal separator regardless of locale —
    /// `String(format:)` uses the C locale, which is what GPX/TCX require.
    private static func num(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }
    /// Coordinates need enough precision (~1 cm) to keep the track faithful.
    private static func coord(_ value: Double) -> String { String(format: "%.7f", value) }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func rideName(for summary: RideSummary) -> String {
        "CycleHUD ride — \(summary.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func fileBaseName(for summary: RideSummary) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "CycleHUD-\(f.string(from: summary.date))"
    }
}
