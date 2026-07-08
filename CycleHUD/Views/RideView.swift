import SwiftUI
import UIKit
import MessageUI
import UniformTypeIdentifiers
import CoreLocation

/// The main riding screen: radar-first, with the data grid and ride controls
/// beneath it. No map.
struct RideView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var ride: RideManager
    @EnvironmentObject var watch: WatchConnectivityManager
    @EnvironmentObject var history: RideHistory
    @EnvironmentObject var weather: WeatherManager
    @EnvironmentObject var sos: SOSManager
    @EnvironmentObject var junctions: JunctionManager
    @EnvironmentObject var routes: RouteStore

    private enum ActiveSheet: Int, Identifiable {
        case pairing, settings, routes
        var id: Int { rawValue }
    }
    @State private var activeSheet: ActiveSheet?
    @State private var carMarkFlash = false
    @State private var pairingFromOnboarding = false
    /// Long-press a tile to edit the grid in place: remove badges, an add tile,
    /// and drag-to-rearrange, closed by a Done button where the controls sit.
    @State private var editingTiles = false
    @State private var draggedTile: MetricKind?
    @State private var showDeletePageConfirm = false
    @State private var showWindDetail = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var showPermissionAlert = false
    @State private var currentIssue: PermissionIssue?
    @State private var dismissedIssueID: String?

    var body: some View {
        ZStack {
            ThemeBackground().ignoresSafeArea()
            GeometryReader { geo in
                let landscape = settings.landscapeEnabled && geo.size.width > geo.size.height
                Group {
                    if landscape { landscapeLayout(geo: geo) } else { portraitLayout(geo: geo) }
                }
                // Re-identify on theme change so memoized leaf views (tiles,
                // radar lane) rebuild with the new palette immediately.
                .id("\(settings.appearanceTheme.rawValue)-\(settings.digitStyle.rawValue)")
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .environment(\.locale, settings.appLocale)
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .pairing: PairingView(showAccessHint: pairingFromOnboarding).environmentObject(ble)
                case .settings: SettingsView().environmentObject(settings).environmentObject(ble)
                        .environmentObject(ride).environmentObject(history).environmentObject(weather)
                        .environmentObject(sos)
                case .routes: RoutesView().environmentObject(routes).environmentObject(settings)
                }
            }
            .preferredColorScheme(appColorScheme).environment(\.locale, settings.appLocale)
        }
        .sheet(item: $ride.finishedSummary) { summary in
            RideSummaryView(summary: summary,
                            effort: ride.canPromptEffort ? { ride.recordEffort($0) } : nil)
                .environmentObject(settings)
                .environmentObject(history)
                .preferredColorScheme(appColorScheme).environment(\.locale, settings.appLocale)
        }
        .fullScreenCover(isPresented: Binding(
            get: { sos.isCountingDown },
            set: { if !$0 { sos.cancel() } }
        )) {
            SOSCountdownView(sos: sos).environment(\.locale, settings.appLocale)
        }
        .sheet(isPresented: $sos.presentComposer) { sosComposer }
        .sheet(isPresented: $showWindDetail) {
            if let c = weather.conditions {
                WindDetailView(conditions: c,
                               heading: location.courseDegrees ?? location.headingDegrees,
                               speedUnit: settings.speedUnit)
                    .presentationDetents([.height(300)])
                    .preferredColorScheme(appColorScheme)
                    .environment(\.locale, settings.appLocale)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasChosenUnits },
            set: { _ in }
        )) {
            UnitsOnboardingView().environmentObject(settings)
                .preferredColorScheme(appColorScheme).environment(\.locale, settings.appLocale)
        }
        .onAppear { updateOrientation(); checkPermissions() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                checkPermissions()
                ble.resumeFromBackground()        // reconnect sensors we dropped
                Task { await weather.refresh(force: true) }   // fresh rain value on return
            case .background:
                // Not riding? Drop sensor connections so the app isn't kept alive
                // in the background processing the radar stream. During a ride
                // (screen off / pocketed) we keep them — the ride needs them.
                if ride.status == .idle && !ride.demoActive {
                    ble.suspendForBackground()
                }
            default:
                break
            }
        }
        .onChange(of: settings.saveWorkouts) { _, _ in checkPermissions(force: true) }
        .alert(currentIssue?.title ?? "Permission needed",
               isPresented: $showPermissionAlert, presenting: currentIssue) { issue in
            if issue.opensAppSettings {
                Button("Open Settings") { Permissions.openAppSettings() }
                Button("Later", role: .cancel) { dismissedIssueID = issue.id }
            } else {
                Button("Don’t save workouts") {
                    settings.saveWorkouts = false
                    dismissedIssueID = issue.id
                }
                Button("OK", role: .cancel) { dismissedIssueID = issue.id }
            }
        } message: { issue in
            Text(issue.message)
        }
        .onChange(of: settings.landscapeEnabled) { _, _ in updateOrientation() }
        .onChange(of: activeSheet) { _, sheet in
            updateOrientation()
            if sheet == nil { pairingFromOnboarding = false; checkPermissions() }
        }
        .onChange(of: ride.finishedSummary) { _, _ in updateOrientation() }
        .onChange(of: settings.hasChosenUnits) { old, new in
            updateOrientation()
            if new && !old {
                // Finishing onboarding drops the rider straight into Devices so
                // they can pair, with a hint on how to get back here later.
                pairingFromOnboarding = true
                // Let the onboarding cover finish dismissing before presenting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    activeSheet = .pairing
                }
            } else if old && !new {
                // Onboarding was reset (from Diagnostics) — close any open sheet
                // so the welcome screen presents instead of hiding behind it.
                activeSheet = nil
            }
        }
    }

    /// The app-wide light/dark choice, applied to presented sheets/covers too so
    /// toggling it updates onboarding and Settings live, not just the main screen.
    private var appColorScheme: ColorScheme { settings.appearanceTheme.colorScheme }

    /// The SOS message composer, or a manual fallback when the device can't send
    /// texts (no SIM/iMessage) — showing the number and message to send by hand.
    @ViewBuilder private var sosComposer: some View {
        if MFMessageComposeViewController.canSendText() {
            MessageComposeView(recipients: sos.recipients, body: sos.messageBody) {
                sos.composerFinished()
            }
            .ignoresSafeArea()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 40)).foregroundStyle(Theme.threatHigh)
                Text("Can’t send a text from this device")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                if let contact = settings.emergencyContact {
                    Text(contact.name.isEmpty ? contact.phone : "\(contact.name) — \(contact.phone)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                Text(sos.messageBody)
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Close") { sos.composerFinished() }
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .padding(.top, 8)
            }
            .padding(28)
        }
    }

    /// Surface any missing OS permission the app relies on. `force` re-shows even
    /// after the rider dismissed it — used when they change a setting (e.g. turn
    /// on workout saving) that introduces a new requirement.
    private func checkPermissions(force: Bool = false) {
        // Only on the main HUD — don't try to present over onboarding or a sheet.
        guard settings.hasChosenUnits, activeSheet == nil else { return }
        let issues = Permissions.currentIssues(saveWorkouts: settings.saveWorkouts)
        guard let first = issues.first else {
            showPermissionAlert = false
            currentIssue = nil
            dismissedIssueID = nil            // re-arm now that everything's resolved
            return
        }
        if force { dismissedIssueID = nil }
        guard dismissedIssueID != first.id else { return }   // already dismissed this one
        currentIssue = first
        showPermissionAlert = true
    }

    /// The HUD is fixed landscape when the setting is on and nothing is presented
    /// over it; every modal (Settings, pairing, the ride summary, onboarding)
    /// drops back to portrait. So the main screen is *always* landscape rather
    /// than rotation-driven, while Settings stays portrait.
    private func updateOrientation() {
        let liveHUD = settings.landscapeEnabled
            && activeSheet == nil
            && ride.finishedSummary == nil
            && settings.hasChosenUnits
        if liveHUD {
            AppDelegate.lock(.landscape, rotateTo: .landscapeRight)
        } else {
            AppDelegate.lock(.portrait, rotateTo: .portrait)
        }
    }

    // MARK: - Layouts

    /// Default stacked layout: status bar, then the swipeable pages (each page:
    /// optional top strip + radar + grid, or a data-only grid), the page dots,
    /// and the controls. While editing, paging locks to the current page so a
    /// tile drag can never cross pages.
    private func portraitLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            statusBar
            if editingTiles {
                portraitPage(settings.currentPage, geo: geo)
            } else {
                TabView(selection: $settings.currentPageIndex) {
                    ForEach(Array(settings.pages.enumerated()), id: \.element.id) { idx, page in
                        portraitPage(page, geo: geo).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            pageDots
            if editingTiles { editToolbar } else { controlBar }
        }
    }

    /// One ride page: radar with tiles above/below it, or (radar hidden) a
    /// data-only grid whose tiles stretch into the freed height.
    @ViewBuilder private func portraitPage(_ page: RidePage, geo: GeometryProxy) -> some View {
        if page.showsRadar {
            VStack(spacing: 12) {
                let top = topKinds(of: page)
                if !top.isEmpty || editingTiles { topStrip(top) }
                radarPanel.frame(maxHeight: .infinity)
                metricsGrid(kinds: bottomKinds(of: page), tileHeight: 90, includeAdd: true)
            }
        } else {
            let all = kinds(of: page)
            let slots = all.count + (editingTiles && !availableTileKinds.isEmpty ? 1 : 0)
            let rows = max(1, Int(ceil(Double(max(1, slots)) / 3.0)))
            let available = geo.size.height - 210   // status, dots, controls, padding
            let fitted = (available - CGFloat(rows - 1) * 8) / CGFloat(rows)
            let tileHeight = max(90, min(150, fitted))
            VStack(spacing: 12) {
                metricsGrid(kinds: all, tileHeight: tileHeight, includeAdd: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// Page indicator dots, just above the controls. Tap to jump.
    @ViewBuilder private var pageDots: some View {
        if settings.pages.count > 1 {
            HStack(spacing: 8) {
                ForEach(settings.pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == settings.pageIndexSafe ? Theme.accent
                                                          : Theme.textSecondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .contentShape(Circle().inset(by: -6))
                        .onTapGesture {
                            guard !editingTiles else { return }
                            withAnimation { settings.currentPageIndex = i }
                        }
                }
            }
        }
    }

    /// Tiles the rider has dragged ABOVE the radar (portrait only). While
    /// editing with none up there yet, a dashed drop zone invites the drag.
    @ViewBuilder private func topStrip(_ top: [MetricKind]) -> some View {
        if top.isEmpty {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.textSecondary.opacity(0.55),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .frame(height: 44)
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.square")
                        Text("Drag tiles here")
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                )
                .contentShape(Rectangle())
                .onDrop(of: [.text], delegate: zoneEndDelegate(true))
        } else {
            metricsGrid(kinds: top, tileHeight: 90, includeAdd: false,
                        zoneIsTop: true)
        }
    }

    /// Landscape split: the top half (status + radar) on the left, the bottom
    /// half (metrics + controls) on the right. The right column is height-bound,
    /// so the tiles are shrunk to fit however many rows the rider has chosen —
    /// otherwise a tall grid would clip the top row and push the controls off.
    private func landscapeLayout(geo: GeometryProxy) -> some View {
        let rowCount = max(1, Int(ceil(Double(gridCellCount) / 3.0)))
        // Right column height ≈ total minus the vertical padding, the control
        // bar and the inter-element spacing.
        let available = geo.size.height - 16 - 58 - 10 - 8
        let rowSpacing: CGFloat = 8
        let fitted = (available - CGFloat(rowCount - 1) * rowSpacing) / CGFloat(rowCount)
        let tileHeight = max(48, min(90, fitted))
        return HStack(spacing: 12) {
            if settings.radarOnRight {
                tilesColumn(tileHeight: tileHeight)
                radarColumn
            } else {
                radarColumn
                tilesColumn(tileHeight: tileHeight)
            }
        }
    }

    private var radarColumn: some View {
        VStack(spacing: 8) {
            statusBar
            radarPanel.frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    /// Landscape: each page's tiles in one column (the portrait top/bottom split
    /// doesn't apply, and the radar column is always shown — pages' radar on/off
    /// is a portrait concept). Swipe to change page; editing locks the page.
    private func tilesColumn(tileHeight: CGFloat) -> some View {
        VStack(spacing: 10) {
            if editingTiles {
                metricsGrid(kinds: visibleMetricKinds, tileHeight: tileHeight, includeAdd: true)
                Spacer(minLength: 0)
            } else {
                TabView(selection: $settings.currentPageIndex) {
                    ForEach(Array(settings.pages.enumerated()), id: \.element.id) { idx, page in
                        VStack(spacing: 10) {
                            metricsGrid(kinds: kinds(of: page), tileHeight: tileHeight,
                                        includeAdd: true)
                            Spacer(minLength: 0)
                        }
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            pageDots
            if editingTiles { editToolbar } else { controlBar }
        }
        .frame(maxWidth: .infinity)
    }

    /// The radar lane plus its debug "Mark car" overlay, shared by both layouts.
    /// With a route being followed and the road behind clear, the slot shows
    /// the route ahead instead — the radar takes it back the moment a vehicle
    /// is detected.
    private var radarPanel: some View {
        Group {
            if ride.demoActive, let demoRoute = ride.demoRoute, ble.threats.isEmpty {
                // Demo finale: glide along a looping demo route so riders see
                // route-following without planning anything.
                RoutePanel(route: demoRoute,
                           location: CLLocation(
                                latitude: demoRoute.path[min(ride.demoRouteIndex, demoRoute.path.count - 1)].lat,
                                longitude: demoRoute.path[min(ride.demoRouteIndex, demoRoute.path.count - 1)].lon),
                           course: demoRoute.bearingAfter(index: ride.demoRouteIndex, lookahead: 20),
                           progress: (index: ride.demoRouteIndex, offMeters: 0,
                                      remainingMeters: demoRoute.remainingMeters(from: ride.demoRouteIndex)),
                           joined: true,
                           leadIn: nil,
                           radarConnected: true,
                           distanceUnit: settings.distanceUnit)
            } else if let route = routes.activeRoute, settings.routePlanningEnabled, ble.threats.isEmpty {
                RoutePanel(route: route,
                           location: location.currentLocation,
                           course: location.courseDegrees ?? location.headingDegrees,
                           progress: location.currentLocation.flatMap {
                               routes.progress(at: $0.coordinate, course: location.courseDegrees)
                           },
                           joined: routes.joinedActiveRoute,
                           leadIn: routes.leadIn,
                           radarConnected: ble.status(for: .radar) == .connected,
                           batteryPercent: ble.radarBatteryPercent,
                           etaSeconds: routeETASeconds,
                           ghostDeltaSeconds: ride.status != .idle
                               ? routes.ghostDelta(elapsed: ride.movingTimeSeconds) : nil,
                           ghostCoordinate: ride.status != .idle
                               ? routes.ghostCoordinate(elapsed: ride.movingTimeSeconds) : nil,
                           showClimbStrip: settings.routeElevationEnabled
                               && !visibleMetricKinds.contains(.climb),
                           junction: settings.junctionsEnabled && !visibleMetricKinds.contains(.junction)
                               ? junctions.next : nil,
                           junctionRouteBearing: junctions.next.flatMap(routeExitBearing),
                           distanceUnit: settings.distanceUnit)
            } else {
                RadarView(threats: ble.threats, distanceUnit: settings.distanceUnit,
                          radarConnected: ble.status(for: .radar) == .connected,
                          batteryPercent: ble.radarBatteryPercent)
            }
        }
            .overlay(alignment: .topTrailing) {
                MuteControls(settings: settings).padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                if settings.radarDebugEnabled { carMarkButton }
            }
            // A radar-only page has no tile to long-press, so the radar itself
            // is an entry into tile editing too.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeInOut(duration: 0.2)) { editingTiles = true }
            })
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            RolePill(label: String(localized: "RAD", comment: "3-letter pill for the Radar sensor"),
                     fullName: String(localized: "Radar"), status: ble.status(for: .radar))
            RolePill(label: String(localized: "SPD", comment: "3-letter pill for the Speed sensor"),
                     fullName: String(localized: "Speed"), status: ble.status(for: .speed))
            RolePill(label: String(localized: "CAD", comment: "3-letter pill for the Cadence sensor"),
                     fullName: String(localized: "Cadence"), status: ble.status(for: .cadence))
            gpsPill

            Spacer(minLength: 4)

            if controlStatus != .idle { statusBadge }

            if settings.routePlanningEnabled {
                Button { activeSheet = .routes } label: {
                    Image(systemName: routes.activeRoute != nil ? "map.fill" : "map")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(routes.activeRoute != nil ? Theme.good : Theme.textPrimary)
                }
                .accessibilityLabel("Routes")
            }
            Button { activeSheet = .pairing } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var gpsPill: some View {
        let connected = location.hasFix
        return Text("GPS")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(connected ? Theme.good : Theme.textSecondary)
            .frame(height: 30)
            .padding(.horizontal, 10)
            .background(Capsule().fill(connected ? Theme.good.opacity(0.18) : Theme.panel))
            .overlay(Capsule().stroke((connected ? Theme.good : Theme.textSecondary)
                .opacity(Theme.pillStrokeOpacity), lineWidth: 1))
            .accessibilityLabel(connected ? "GPS: fix acquired" : "GPS: searching")
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(statusColor.opacity(0.18)))
            .overlay(Capsule().stroke(statusColor.opacity(Theme.pillStrokeOpacity), lineWidth: 1))
    }

    /// The status that drives the badge and controls — the demo presents itself
    /// as a running (or paused) ride so the bottom controls behave normally.
    private var controlStatus: RideStatus {
        guard ride.demoActive else { return ride.status }
        return ride.demoPaused ? .paused : .running
    }

    private var statusText: String {
        switch controlStatus {
        case .idle: return String(localized: "STOPPED")
        case .running: return "● " + String(localized: "REC")
        case .paused: return String(localized: "PAUSED")
        case .autoPaused: return String(localized: "AUTO-PAUSED")
        }
    }

    private var statusColor: Color {
        switch controlStatus {
        case .idle: return Theme.textSecondary
        case .running: return Theme.threatHigh
        case .paused, .autoPaused: return Theme.threatLow
        }
    }

    // MARK: - Metrics

    /// Whether a tile kind is usable given the current data-source settings
    /// (weather tiles need Weather on; the junction tile needs Junctions on).
    private func usable(_ kind: MetricKind) -> Bool {
        (!kind.requiresWeather || settings.weatherEnabled)
            && (!kind.requiresJunctions || settings.junctionsEnabled)
    }

    /// A page's visible tiles: valid kinds, data-source-gated tiles removed.
    private func kinds(of page: RidePage) -> [MetricKind] {
        page.tiles.compactMap(MetricKind.init(rawValue:)).filter(usable)
    }

    /// A page's tiles above the radar (its leading `topTileCount` entries).
    private func topKinds(of page: RidePage) -> [MetricKind] {
        let split = min(max(0, page.topTileCount), page.tiles.count)
        return page.tiles.prefix(split)
            .compactMap(MetricKind.init(rawValue:))
            .filter(usable)
    }

    /// A page's tiles below the radar.
    private func bottomKinds(of page: RidePage) -> [MetricKind] {
        let split = min(max(0, page.topTileCount), page.tiles.count)
        return page.tiles.dropFirst(split)
            .compactMap(MetricKind.init(rawValue:))
            .filter(usable)
    }

    /// The CURRENT page's visible tiles (landscape fit, edit-mode guards).
    private var visibleMetricKinds: [MetricKind] { kinds(of: settings.currentPage) }

    /// Metrics not currently in the grid (and usable, given the data-source
    /// settings), offered by the edit-mode add tile.
    private var availableTileKinds: [MetricKind] {
        let chosen = Set(settings.metricTiles)
        return MetricKind.allCases.filter { !chosen.contains($0.rawValue) && usable($0) }
    }

    /// One slot in the tile grid: a metric, or (while editing) the add button.
    private enum GridCell {
        case metric(MetricKind)
        case add
    }

    /// How many grid slots are showing — drives the landscape height fit.
    /// A full-row tile (the climb row) counts as a whole row of three.
    private var gridCellCount: Int {
        visibleMetricKinds.reduce(0) { $0 + ($1.isFullRow ? 3 : 1) }
            + (editingTiles && !availableTileKinds.isEmpty ? 1 : 0)
    }

    /// `kinds` laid out three per row at `tileHeight`; short rows are padded so
    /// tile widths stay uniform, and full-row tiles (the climb row) get a row
    /// of their own. Long-press any tile to edit the grid in place. While
    /// editing, the free space — padded slots, the gaps between tiles and the
    /// grid background — accepts drops too (move to the end of this zone), so
    /// a drag doesn't have to land exactly on another tile.
    private func metricsGrid(kinds: [MetricKind], tileHeight: CGFloat,
                             includeAdd: Bool, zoneIsTop: Bool = false) -> some View {
        var cells: [GridCell] = kinds.map { .metric($0) }
        if includeAdd && editingTiles && !availableTileKinds.isEmpty { cells.append(.add) }
        var rows: [[GridCell]] = []
        var current: [GridCell] = []
        for cell in cells {
            if case .metric(let kind) = cell, kind.isFullRow {
                if !current.isEmpty { rows.append(current); current = [] }
                rows.append([cell])
            } else {
                current.append(cell)
                if current.count == 3 { rows.append(current); current = [] }
            }
        }
        if !current.isEmpty { rows.append(current) }
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.count == 1, case .metric(let kind) = row[0], kind.isFullRow {
                    gridCell(row[0], height: tileHeight, zoneIsTop: zoneIsTop)
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            if i < row.count {
                                gridCell(row[i], height: tileHeight, zoneIsTop: zoneIsTop)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: tileHeight)
                                    .contentShape(Rectangle())
                                    .onDrop(of: [.text], delegate: zoneEndDelegate(zoneIsTop))
                            }
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.text], delegate: zoneEndDelegate(zoneIsTop))
    }

    private func zoneEndDelegate(_ zoneIsTop: Bool) -> ZoneEndDropDelegate {
        ZoneEndDropDelegate(zoneIsTop: zoneIsTop, dragged: $draggedTile, settings: settings)
    }

    @ViewBuilder
    private func gridCell(_ cell: GridCell, height: CGFloat, zoneIsTop: Bool) -> some View {
        switch cell {
        case .metric(let kind): tileCell(for: kind, height: height)
        case .add:
            // The "+" tile doubles as a drop target: dropping here = end of grid.
            addTile(height: height)
                .onDrop(of: [.text], delegate: zoneEndDelegate(zoneIsTop))
        }
    }

    // MARK: - In-place tile editing

    /// A tile plus its edit-mode chrome. Normal mode: the live tile, long-press
    /// to start editing. Edit mode: the tile's own taps are disabled, a remove
    /// badge sits on its corner, and it can be dragged onto another tile to
    /// rearrange (the underlying order updates live as the drag passes over).
    @ViewBuilder
    private func tileCell(for kind: MetricKind, height: CGFloat) -> some View {
        if editingTiles {
            ZStack {
                metricTile(for: kind, height: height)
                    .allowsHitTesting(false)      // e.g. the rain tile's tap sheet
                // A hit-testable layer over the (now inert) tile so the drag
                // gesture has something to grab.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            // Clip the system drag "lift" preview to the tile's rounded shape, so
            // the snapshot doesn't carry square corners of background colour.
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 16))
            .onDrag {
                draggedTile = kind
                return NSItemProvider(object: kind.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: TileDropDelegate(target: kind,
                                                            dragged: $draggedTile,
                                                            settings: settings))
            .overlay(alignment: .topLeading) {
                // Keep a long-press target on the page: the last tile may only
                // be removed when the radar remains (it accepts a long-press).
                if visibleMetricKinds.count > 1 || settings.currentPage.showsRadar {
                    removeBadge(kind)
                }
            }
        } else {
            metricTile(for: kind, height: height)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.2)) { editingTiles = true }
                })
        }
    }

    private func removeBadge(_ kind: MetricKind) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                // Removing a tile from the above-radar strip shrinks the split.
                if let idx = settings.metricTiles.firstIndex(of: kind.rawValue),
                   idx < settings.topTileCount {
                    settings.topTileCount -= 1
                }
                settings.metricTiles.removeAll { $0 == kind.rawValue }
            }
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.threatHigh)
                .background(Circle().fill(.white).padding(3))
        }
        .offset(x: -7, y: -7)
        .accessibilityLabel("Remove tile")
    }

    /// Dashed "+" tile at the end of the grid in edit mode: tap for a menu of
    /// the metrics not currently shown.
    private func addTile(height: CGFloat) -> some View {
        Menu {
            ForEach(availableTileKinds) { kind in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.metricTiles.append(kind.rawValue)
                    }
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.textSecondary.opacity(0.55),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add tile")
    }

    /// Replaces the ride controls while editing, so a drag can't hit Stop:
    /// page management (delete / radar on-off / add) plus Done.
    private var editToolbar: some View {
        HStack(spacing: 10) {
            if settings.pages.count > 1 {
                editTool("trash", color: Theme.threatHigh) { showDeletePageConfirm = true }
                    .accessibilityLabel("Delete page")
                    .confirmationDialog("Delete this page?",
                                        isPresented: $showDeletePageConfirm,
                                        titleVisibility: .visible) {
                        Button("Delete page", role: .destructive) { deleteCurrentPage() }
                        Button("Cancel", role: .cancel) {}
                    }
            }
            editTool(settings.currentPage.showsRadar
                        ? "antenna.radiowaves.left.and.right.slash"
                        : "antenna.radiowaves.left.and.right",
                     color: Theme.textPrimary) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settings.pages[settings.pageIndexSafe].showsRadar.toggle()
                }
            }
            .accessibilityLabel(settings.currentPage.showsRadar ? "Hide radar" : "Show radar")
            editTool("plus.rectangle.on.rectangle", color: Theme.textPrimary) { addPage() }
                .accessibilityLabel("Add page")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    editingTiles = false
                    draggedTile = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                    Text("Done")
                }
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent))
            }
        }
    }

    private func editTool(_ icon: String, color: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
        }
    }

    /// New page right after the current one, empty and radar-on; jump to it.
    private func addPage() {
        withAnimation(.easeInOut(duration: 0.2)) {
            let idx = settings.pageIndexSafe + 1
            settings.pages.insert(RidePage(tiles: []), at: idx)
            settings.currentPageIndex = idx
        }
    }

    private func deleteCurrentPage() {
        guard settings.pages.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            settings.pages.remove(at: settings.pageIndexSafe)
            settings.currentPageIndex = settings.pageIndexSafe   // re-clamp
        }
    }

    /// Value font scaled to the tile height so shrunken landscape tiles still
    /// fit; with units hidden the freed space goes to bigger numerals.
    private func valueSize(for height: CGFloat) -> CGFloat {
        let cap: CGFloat = settings.showTileUnits ? 32 : 36
        return max(22, min(cap, height * 0.42))
    }

    /// The tile's unit label, or nothing when the rider has hidden units.
    private func tileUnit(_ unit: String) -> String {
        settings.showTileUnits ? unit : ""
    }

    /// Build the tile for one metric, pulling live values from the managers.
    @ViewBuilder
    private func metricTile(for kind: MetricKind, height: CGFloat) -> some View {
        let vs = valueSize(for: height)
        switch kind {
        case .speed:
            MetricTile(title: kind.title, value: speedString(ride.currentSpeedMps),
                       unit: tileUnit(settings.speedUnit.label), valueSize: vs, height: height)
        case .avgSpeed:
            MetricTile(title: kind.title, value: speedString(ride.averageSpeedMps),
                       unit: tileUnit(settings.speedUnit.label), valueSize: vs, height: height)
        case .maxSpeed:
            MetricTile(title: kind.title, value: speedString(ride.maxSpeedMps),
                       unit: tileUnit(settings.speedUnit.label), valueSize: vs, height: height)
        case .cadence:
            MetricTile(title: kind.title, value: ble.freshCadence.map { Fmt.int($0) } ?? "—",
                       unit: tileUnit("rpm"), valueSize: vs, height: height)
        case .distance:
            MetricTile(title: kind.title, value: distanceString(ride.distanceMeters),
                       unit: tileUnit(settings.distanceUnit.label), valueSize: vs, height: height)
        case .time:
            MetricTile(title: kind.title, value: timeString(ride.movingTimeSeconds),
                       unit: "", valueSize: vs, height: height)
        case .ascent:
            MetricTile(title: kind.title, value: elevationString(ride.elevationGainMeters),
                       unit: tileUnit(settings.distanceUnit.shortLabel), valueSize: vs, height: height)
        case .heartRate:
            let hr = watch.displayHeartRate ?? ride.currentHeartRate ?? ble.freshSensorHeartRate()
            MetricTile(title: kind.title, value: hr.map { Fmt.int($0) } ?? "—",
                       unit: tileUnit("bpm"), valueSize: vs, height: height,
                       alert: settings.hrWarningEnabled && (hr ?? 0) >= settings.hrWarningBpm)
        case .calories:
            MetricTile(title: kind.title, value: ride.caloriesKcal >= 1 ? Fmt.int(ride.caloriesKcal) : "—",
                       unit: tileUnit("kcal"), valueSize: vs, height: height)
        case .gradient:
            MetricTile(title: kind.title, value: gradientString, unit: tileUnit("%"),
                       valueSize: vs, height: height)
        case .lapTime:
            MetricTile(title: kind.title, value: timeString(ride.currentLapTimeSeconds),
                       unit: "", valueSize: vs, height: height)
        case .temperature:
            MetricTile(title: kind.title, value: temperatureValue, unit: tileUnit(temperatureUnit),
                       valueSize: vs, height: height)
        case .wind:
            windTile(height: height, valueSize: vs)
        case .compass:
            compassTile(height: height, valueSize: vs)
        case .junction:
            junctionTile(height: height, valueSize: vs)
        case .climb:
            climbRowTile(height: height, valueSize: vs)
        case .rain:
            WeatherTile(nowcast: weather.nowcast, status: weather.status, height: height,
                        showUnit: settings.showTileUnits)
        }
    }

    /// Live road gradient as a signed percentage (— until enough travel).
    private var gradientString: String {
        guard let g = ride.currentGradientPercent else { return "—" }
        return Fmt.decimal(g, 1)
    }

    /// Imperial temperature (°F) when the rider uses miles, otherwise °C.
    private var imperialTemperature: Bool { settings.distanceUnit == .mi }
    private var temperatureUnit: String { imperialTemperature ? "°F" : "°C" }
    private var temperatureValue: String {
        guard let c = weather.conditions else { return "—" }
        let t = imperialTemperature ? c.temperatureC * 9 / 5 + 32 : c.temperatureC
        return Fmt.int(t)
    }

    /// Wind speed with a direction arrow: the arrow shows where the wind is
    /// blowing relative to your direction of travel (GPS course while moving,
    /// compass heading when stopped) — pointing down = headwind, up = tailwind —
    /// and is tinted by the head/tail component.
    private func windTile(height: CGFloat, valueSize vs: CGFloat) -> some View {
        let heading = location.courseDegrees ?? location.headingDegrees
        let c = weather.conditions
        var arrow: Double?
        var color = Theme.accent
        // The number is the HEADWIND/TAILWIND component along your heading (the
        // figure that actually costs or gives you speed — same as the detail
        // view); the arrow carries the direction. Falls back to the absolute
        // wind speed only when no heading is known yet.
        var valueMps = c?.windSpeedMps
        if let c, let heading {
            // windFromDegrees is where the wind comes FROM; the arrow shows
            // where it's blowing TOWARD, in the rider's frame (up = ahead).
            arrow = (c.windFromDegrees + 180 - heading).truncatingRemainder(dividingBy: 360)
            let head = c.headwindMps(course: heading)
            valueMps = abs(head)
            if head > 1 { color = Theme.threatMedium }        // fighting it
            else if head < -1 { color = Theme.good }          // free speed
        }
        return Button {
            if weather.conditions != nil { showWindDetail = true }
        } label: {
            DirectionTile(title: "Wind",
                          value: valueMps.map { Fmt.int(settings.speedUnit.value(fromMps: $0)) } ?? "—",
                          unit: c != nil ? tileUnit(settings.speedUnit.label) : "",
                          valueSize: vs, height: height,
                          arrowDegrees: arrow, arrowColor: color)
        }
        .buttonStyle(.plain)
    }

    /// The distance-and-climb row: distance / live gradient / ascent overlaid
    /// on the active route's elevation profile (with the rider's position
    /// marked). Takes a full grid row; the route map drops its own climb
    /// strip while this row is on the page.
    private func climbRowTile(height: CGFloat, valueSize vs: CGFloat) -> some View {
        let route = settings.routePlanningEnabled ? routes.activeRoute : nil
        var ridden: Double?
        if let route, routes.joinedActiveRoute, let loc = location.currentLocation,
           let progress = routes.progress(at: loc.coordinate, course: location.courseDegrees) {
            ridden = max(0, route.remainingMeters(from: 0) - progress.remainingMeters)
        }
        return ClimbRowTile(route: route,
                            progressMeters: ridden,
                            distanceValue: distanceString(ride.distanceMeters),
                            distanceUnit: tileUnit(settings.distanceUnit.label),
                            gradientValue: gradientString,
                            gradientUnit: tileUnit("%"),
                            ascentValue: elevationString(ride.elevationGainMeters),
                            ascentUnit: tileUnit(settings.distanceUnit.shortLabel),
                            valueSize: vs, height: height)
    }

    /// The next intersection ahead (OpenStreetMap): distance counting down in
    /// the rider's units, with a schematic of the junction's arms. When a
    /// planned route passes through the junction, the arm the route takes is
    /// highlighted green — the tile points the way.
    private func junctionTile(height: CGFloat, valueSize vs: CGFloat) -> some View {
        let info = junctions.next
        let value = info.map { Fmt.int(settings.distanceUnit.shortValue(fromMeters: $0.distanceMeters)) } ?? "—"
        return JunctionTile(title: "Junction", value: value,
                            unit: info != nil ? tileUnit(settings.distanceUnit.shortLabel) : "",
                            valueSize: vs, height: height, info: info,
                            routeBearing: info.flatMap(routeExitBearing))
    }

    /// The direction the active route leaves `junction`, or nil when no route
    /// is being followed or it doesn't pass through this junction. Anchored
    /// FORWARD from the rider's progress along the route, so on an
    /// out-and-back road the junction gets the homebound direction on the way
    /// home, not the outbound one.
    private func routeExitBearing(at junction: JunctionInfo) -> Double? {
        guard settings.routePlanningEnabled, let route = routes.activeRoute else { return nil }
        let coord = CLLocationCoordinate2D(latitude: junction.latitude,
                                           longitude: junction.longitude)
        guard let near = route.nearestPathIndex(to: coord,
                                                hint: routes.currentPathIndex,
                                                windowMeters: 1600),
              near.meters <= 30 else { return nil }
        return route.bearingAfter(index: near.index, lookahead: 25)
    }

    /// Estimated time to the route finish at the ride's average speed (nil
    /// until there's a meaningful average to project from).
    private var routeETASeconds: Double? {
        guard ride.averageSpeedMps > 0.5,
              let loc = location.currentLocation,
              let progress = routes.progress(at: loc.coordinate, course: location.courseDegrees)
        else { return nil }
        return progress.remainingMeters / ride.averageSpeedMps
    }

    /// A needle that always points north — no number, just the arrow.
    private func compassTile(height: CGFloat, valueSize vs: CGFloat) -> some View {
        let heading = location.courseDegrees ?? location.headingDegrees
        return DirectionTile(title: "Compass", valueSize: vs, height: height,
                             arrowDegrees: heading.map { -$0 }, arrowColor: Theme.accent)
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            if controlStatus == .idle {
                primaryButton(title: "Start", system: "play.fill", color: Theme.good, cta: true) {
                    ble.stopDemo()
                    ride.start()
                }
            } else {
                if controlStatus == .running && !ride.demoActive { lapButton }
                primaryButton(title: controlStatus == .running ? "Pause" : "Resume",
                              system: controlStatus == .running ? "pause.fill" : "play.fill",
                              color: Theme.accent) {
                    ride.demoActive ? ride.toggleDemoPause() : ride.togglePause()
                }
                primaryButton(title: "Stop", system: "stop.fill", color: Theme.threatHigh) {
                    if ride.demoActive {
                        ble.stopDemo()
                        ride.stopDemo()
                    } else {
                        ride.stop()
                    }
                }
            }
        }
    }

    /// Compact icon-only lap button: closes the current lap and starts a new one.
    private var lapButton: some View {
        Button {
            ride.markLap()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Image(systemName: "flag.checkered")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
        }
        .accessibilityLabel("Mark lap")
    }

    private func primaryButton(title: LocalizedStringKey, system: String, color: Color,
                               cta: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: system)
                Text(title)
            }
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(cta ? Theme.ctaStyle(color) : AnyShapeStyle(color))
                .shadow(color: Theme.glow, radius: 10))
        }
    }

    // MARK: - Car mark (protocol-decode aid)

    /// Tapped when a real car passes, to drop a timestamp in the log so sparse
    /// car events can be matched against captured radar packets.
    private var carMarkButton: some View {
        Button {
            ble.markCarObserved()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeOut(duration: 0.12)) { carMarkFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeIn(duration: 0.3)) { carMarkFlash = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                Text(carMarkFlash ? String(localized: "Marked \(ble.carMarkCount)") : String(localized: "Mark car"))
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(carMarkFlash ? Theme.good : Color.black.opacity(0.55)))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .padding(12)
        .accessibilityLabel("Mark that a car just passed")
    }

    // MARK: - Formatting

    private func speedString(_ mps: Double) -> String {
        Fmt.decimal(settings.speedUnit.value(fromMps: mps), 1)
    }

    private func distanceString(_ meters: Double) -> String {
        Fmt.decimal(settings.distanceUnit.value(fromMeters: meters), 2)
    }

    private func elevationString(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return Fmt.int(settings.distanceUnit.shortValue(fromMeters: meters))
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

/// Reorders the tile grid live while a dragged tile passes over its neighbours:
/// entering another tile's bounds moves the dragged metric to that position in
/// the persisted order (weather-hidden tiles keep their relative place).
private struct TileDropDelegate: DropDelegate {
    let target: MetricKind
    @Binding var dragged: MetricKind?
    let settings: AppSettings

    func dropEntered(info: DropInfo) {
        guard let draggedKind = dragged, draggedKind != target,
              let from = settings.metricTiles.firstIndex(of: draggedKind.rawValue),
              let to = settings.metricTiles.firstIndex(of: target.rawValue) else { return }
        // Dropping onto a tile joins that tile's zone (above/below the radar),
        // so the split index follows the move.
        let top = min(settings.topTileCount, settings.metricTiles.count)
        let fromTop = from < top
        let targetTop = to < top
        withAnimation(.easeInOut(duration: 0.2)) {
            var tiles = settings.metricTiles
            tiles.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            settings.metricTiles = tiles
            if fromTop != targetTop {
                settings.topTileCount = top + (targetTop ? 1 : -1)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// Drop target for a zone's free space (padded slots, gaps, the grid backdrop,
/// the empty top strip, the "+" tile): moves the dragged tile to the END of
/// that zone, adjusting the above-radar split when the drag crosses zones. This
/// is what lets a drag land in open space instead of exactly on another tile.
private struct ZoneEndDropDelegate: DropDelegate {
    let zoneIsTop: Bool
    @Binding var dragged: MetricKind?
    let settings: AppSettings

    func dropEntered(info: DropInfo) { moveToZoneEnd() }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        moveToZoneEnd()
        dragged = nil
        return true
    }

    private func moveToZoneEnd() {
        guard let kind = dragged,
              let from = settings.metricTiles.firstIndex(of: kind.rawValue) else { return }
        let top = min(settings.topTileCount, settings.metricTiles.count)
        let fromTop = from < top
        // Already the last tile of this zone — nothing to move (also stops the
        // repeated dropEntered calls from thrashing the array).
        let zoneEnd = zoneIsTop ? top - 1 : settings.metricTiles.count - 1
        if fromTop == zoneIsTop && from == zoneEnd { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            var tiles = settings.metricTiles
            tiles.move(fromOffsets: IndexSet(integer: from),
                       toOffset: zoneIsTop ? top : tiles.count)
            settings.metricTiles = tiles
            if fromTop != zoneIsTop {
                settings.topTileCount = top + (zoneIsTop ? 1 : -1)
            }
        }
    }
}

/// Connection-status pill for a sensor role: shows connected (green),
/// connecting (spinner), retrying (rotating arrow), failed (red), or not set up.
struct RolePill: View {
    let label: String
    let fullName: String
    let status: RoleStatus

    @State private var spin = false

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
            trailing
        }
        .foregroundStyle(status.color)
        .frame(height: 30)
        .padding(.horizontal, 10)
        .background(Capsule().fill(status == .connected
                                   ? Theme.good.opacity(0.18) : Theme.panel))
        .overlay(
            Capsule().stroke(status.color.opacity(status == .failed ? 0.8 : Theme.pillStrokeOpacity),
                             lineWidth: 1)
        )
        .accessibilityLabel("\(fullName): \(status.detail)")
    }

    /// Only non-connected states add a glyph; connected reads as a plain green icon.
    @ViewBuilder private var trailing: some View {
        if status.showsSpinner {
            ProgressView()
                .controlSize(.mini)
                .tint(status.color)
        } else if status.showsRetry {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
        } else if status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
        }
    }
}
