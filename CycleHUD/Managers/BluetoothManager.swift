import Foundation
import CoreBluetooth
import SwiftUI
import Combine
import UIKit

enum DeviceRole: String, Codable, CaseIterable {
    case radar = "Radar"
    case speed = "Speed"
    case cadence = "Cadence"

    var systemImage: String {
        switch self {
        case .radar: return "dot.radiowaves.left.and.right"
        case .speed: return "speedometer"
        case .cadence: return "bicycle"
        }
    }
}

/// Live connection state of a single peripheral.
enum ConnectionState {
    case connecting     // first connection attempt in progress
    case connected
    case retrying       // dropped / failed — auto-reconnect pending
}

/// Aggregated state for a *role* (radar / sensor), used by the main-screen icons.
enum RoleStatus {
    case notConfigured   // no remembered device for this role
    case connecting
    case connected
    case retrying
    case failed          // configured but Bluetooth is off / unavailable

    var color: Color {
        switch self {
        case .notConfigured: return Theme.textSecondary
        case .connecting, .retrying: return Theme.threatMedium   // orange reads better than yellow
        case .connected: return Theme.good
        case .failed: return Theme.threatHigh
        }
    }

    var showsSpinner: Bool { self == .connecting }
    var showsRetry: Bool { self == .retrying }

    var detail: String {
        switch self {
        case .notConfigured: return "Not set up"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .retrying: return "Reconnecting…"
        case .failed: return "Unavailable"
        }
    }
}

/// A peripheral surfaced in the pairing screen.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var roles: Set<DeviceRole>

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool { lhs.id == rhs.id }
}

/// A remembered device, persisted across launches.
struct SavedDevice: Codable, Identifiable {
    let id: UUID
    var name: String
    var roles: [DeviceRole]
}

/// Owns all Bluetooth LE work: scanning/pairing, the Varia-compatible rear
/// radar, a standard CSC speed/cadence sensor, persistent reconnection, and a
/// self-contained demo mode.
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: BLE identifiers

    static let radarService = CBUUID(string: "6A4E3200-667B-11E3-949A-0800200C9A66")
    static let radarMeasurement = CBUUID(string: "6A4E3203-667B-11E3-949A-0800200C9A66")
    // Some Varia-compatible radars (incl. some Coospo firmware) use this family.
    static let radarServiceAlt = CBUUID(string: "6A4ECD65-D688-4A4C-A37D-CF5AF0DBEDD0")
    static let radarMeasurementAlt = CBUUID(string: "6A4ECD66-D688-4A4C-A37D-CF5AF0DBEDD0")
    static let radarMeasurementUUIDs: Set<CBUUID> = [radarMeasurement, radarMeasurementAlt]
    // Coospo TR70 uses proprietary services over BLE (FDB0 is radar-unique).
    static let coospoRadarService = CBUUID(string: "FDB0")
    // FDB1 = radar data (notify); FDB2 = radar control (write without response).
    static let coospoRadarData = CBUUID(string: "FDB1")
    static let coospoRadarControl = CBUUID(string: "FDB2")
    // The TR70 streams radar data on FDB1 only while it's periodically poked with
    // this command on FDB2 (captured from the CoospoRide app). Format is
    // [opcode][len][params…][checksum = sum of prior bytes & 0xFF]; B8 05 02 01
    // is "radar on", C0 the checksum. Resent on a keepalive or the radar stops.
    static let coospoRadarEnableCommand = Data([0xB8, 0x05, 0x02, 0x01, 0xC0])
    // CoospoRide also writes this to FDB2 — believed to put the radar into active
    // threat-detection mode (the enable/keepalive alone makes it stream the
    // heartbeat but not detect cars). Sent once on connect.
    static let coospoRadarActivateCommand = Data([0xB8, 0x05, 0x23, 0x01, 0xE1])
    // FDB1 frame: [0xC8][len][page][payload…][checksum]. Page 0x24 is the threat
    // list (all-zero target bytes when clear); other pages are status/heartbeat.
    static let coospoRadarThreatPage: UInt8 = 0x24
    static let radarServiceUUIDs: Set<CBUUID> = [radarService, radarServiceAlt, coospoRadarService]
    static let cscService = CBUUID(string: "1816")
    static let cscMeasurement = CBUUID(string: "2A5B")
    static let batteryLevel = CBUUID(string: "2A19")   // standard 0–100% battery
    private let savedDevicesKey = "savedDevicesV3"

    // MARK: Published state

    @Published private(set) var poweredOn = false
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredDevice] = []

    @Published private(set) var savedDevices: [SavedDevice] = []
    @Published private(set) var connectionStates: [UUID: ConnectionState] = [:]

    @Published private(set) var threats: [Threat] = []
    @Published private(set) var radarBatteryPercent: Int?   // radar's battery (0–100)
    @Published private(set) var demoActive = false

    /// Human-readable BLE diagnostics (services/characteristics found, radar
    /// packets) shown in the Diagnostics screen to debug sensors in the field.
    @Published private(set) var diagnostics: [String] = []
    private func diag(_ line: String) {
        diagnostics.append(line)
        if diagnostics.count > 300 { diagnostics.removeFirst(diagnostics.count - 300) }
        AppLog.shared.log("BLE: \(line)")
    }

    @Published private(set) var sensorSpeedMps: Double?
    @Published private(set) var cadenceRpm: Int?
    private var sensorSpeedUpdatedAt: Date?
    private var cadenceUpdatedAt: Date?

    private let settings: AppSettings
    private var central: CBCentralManager!
    private var connected: [UUID: CBPeripheral] = [:]
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    // True while the app is backgrounded and NOT riding: sensor connections are
    // dropped so the bluetooth-central background mode can't keep the app alive
    // processing the radar's stream. Reconnected on return to the foreground.
    private var backgroundSuspended = false

    // After a ride ends we watch (up to 5 min) whether the sensors are still on,
    // and if so remind the rider to switch them off (they have their own
    // batteries). The check piggybacks on the sensors' own stream, so it costs
    // nothing once they're actually switched off.
    private var sensorMonitorStartedAt: Date?
    private var sensorReminderSent = false
    private static let sensorReminderDelay: TimeInterval = 300   // 5 minutes

    // Liveness: a sensor counts as connected only while it's actually streaming
    // data (CoreBluetooth can report a powered-off sensor as connected for ages).
    private var lastDataAt: [UUID: Date] = [:]
    // When a *radar frame* last arrived. Distinct from lastDataAt (which is also
    // seeded on connect and bumped by battery reads) so the radar only reads as
    // connected while it's genuinely streaming — never on a bare BLE link.
    private var lastRadarFrameAt: [UUID: Date] = [:]
    private var livenessTimer: Timer?
    private let dataTimeout: TimeInterval = 10        // CSC sensors (can be sparse)
    // Radar streams a ~2 Hz heartbeat, so a few seconds of silence means it's
    // gone. Kept short because it's a safety device, but long enough to ride out
    // a brief BLE stall (~8 missed heartbeats) without flickering.
    private let radarDataTimeout: TimeInterval = 4

    // Coospo radar control: the FDB2 characteristic per radar peripheral, poked
    // periodically to keep the TR70 streaming radar data on FDB1.
    private var radarControlChars: [UUID: CBCharacteristic] = [:]
    private var radarKeepAliveTimer: Timer?

    // CSC running state for delta calculations.
    private var lastWheelRevs: UInt32?
    private var lastWheelEventTime: UInt16?
    private var lastCrankRevs: UInt16?
    private var lastCrankEventTime: UInt16?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        loadSavedDevices()
        central = CBCentralManager(delegate: self, queue: nil)
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkLiveness()
        }
    }

    /// Watchdog for sensors that have gone quiet.
    ///
    /// Every supported sensor streams continuously while powered: a CSC sensor
    /// reports periodically, and the radar sends a ~2 Hz heartbeat (plus an empty
    /// threat page) even with no vehicles behind. So a silence longer than the
    /// sensor's timeout reliably means it's gone — CoreBluetooth can keep
    /// reporting a powered-off device as "connected" well after the fact, so we
    /// trust the data, not the link.
    ///
    /// The radar gets a short timeout because it's a safety device: if it's off,
    /// the rider must see "NOT CONNECTED" quickly, and stale cars are cleared.
    private func checkLiveness() {
        let now = Date()
        for (id, peripheral) in connected where peripheral.state == .connected {
            guard connectionStates[id] == .connected else { continue }
            let isRadar = (peripheral.services ?? []).contains {
                BluetoothManager.radarServiceUUIDs.contains($0.uuid)
            }
            let timeout = isRadar ? radarDataTimeout : dataTimeout
            guard now.timeIntervalSince(lastDataAt[id] ?? .distantPast) > timeout else { continue }

            connectionStates[id] = .retrying       // heartbeat stopped → treat as gone
            if isRadar { threats = [] }            // safety: never show stale cars
        }
        // Prune threats we haven't seen recently so a car that has passed can't
        // linger on the lane (covers radars that don't send an explicit "clear").
        if !demoActive {
            let fresh = threats.filter { now.timeIntervalSince($0.lastSeen) <= 5 }
            if fresh.count != threats.count { threats = fresh }
        }
    }

    // MARK: - Role / device status (for the main-screen icons)

    func status(for role: DeviceRole) -> RoleStatus {
        if demoActive { return .connected }   // demo: show everything live
        let matching = savedDevices.filter { $0.roles.contains(role) }
        guard !matching.isEmpty else { return .notConfigured }
        if !poweredOn { return .failed }
        let now = Date()
        let states: [ConnectionState] = matching.map { dev in
            let s = connectionStates[dev.id] ?? .retrying
            // A radar that's BLE-linked but not actually streaming isn't watching
            // the road — e.g. switched off while iOS still reports the link, or a
            // momentary auto-reconnect with no data. Require a recent radar frame
            // before calling it connected, so the status can't flicker green when
            // the radar is really off. (Other sensors keep the simple link check.)
            if role == .radar, s == .connected,
               now.timeIntervalSince(lastRadarFrameAt[dev.id] ?? .distantPast) > radarDataTimeout {
                return .connecting
            }
            return s
        }
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) { return .connecting }
        return .retrying
    }

    func deviceState(_ id: UUID) -> ConnectionState {
        connectionStates[id] ?? .retrying
    }

    // MARK: - Scanning / pairing

    private var scanTimeoutTimer: Timer?

    func startScan() {
        guard poweredOn else { return }
        discovered.removeAll()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        // BLE scanning is power-hungry; sensors appear within seconds. Auto-stop
        // after 30 s so a leaked scan (e.g. the pairing sheet dismissing without
        // its onDisappear firing) can't drain the battery for a whole ride.
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    func stopScan() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        central.stopScan()
        isScanning = false
    }

    func connect(_ id: UUID) {
        guard let peripheral = discoveredPeripherals[id]
                ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripheral.delegate = self
        connected[id] = peripheral
        connectionStates[id] = .connecting
        central.connect(peripheral, options: nil)
    }

    func forget(_ id: UUID) {
        if let peripheral = connected[id] {
            central.cancelPeripheralConnection(peripheral)
        }
        connected[id] = nil
        connectionStates[id] = nil
        clearRadarControl(for: id)
        savedDevices.removeAll { $0.id == id }
        persistSavedDevices()
        recomputeRadarThreatsIfNeeded()
    }

    // MARK: - Persistence / auto-reconnect

    private func loadSavedDevices() {
        guard let data = UserDefaults.standard.data(forKey: savedDevicesKey),
              let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) else { return }
        savedDevices = decoded
    }

    private func persistSavedDevices() {
        if let data = try? JSONEncoder().encode(savedDevices) {
            UserDefaults.standard.set(data, forKey: savedDevicesKey)
        }
    }

    private func upsertSavedDevice(id: UUID, name: String, addRole role: DeviceRole? = nil) {
        if let idx = savedDevices.firstIndex(where: { $0.id == id }) {
            if !name.isEmpty { savedDevices[idx].name = name }
            if let role, !savedDevices[idx].roles.contains(role) {
                savedDevices[idx].roles.append(role)
            }
        } else {
            savedDevices.append(SavedDevice(id: id, name: name.isEmpty ? "Sensor" : name,
                                            roles: role.map { [$0] } ?? []))
        }
        persistSavedDevices()
    }

    /// Add a detected capability to an already-remembered device (no-op if
    /// already present, so it won't thrash UserDefaults on every packet).
    private func markCapability(_ role: DeviceRole, for id: UUID) {
        guard let idx = savedDevices.firstIndex(where: { $0.id == id }),
              !savedDevices[idx].roles.contains(role) else { return }
        savedDevices[idx].roles.append(role)
        persistSavedDevices()
    }

    private func reconnectSavedDevices() {
        let ids = savedDevices.map(\.id)
        guard !ids.isEmpty else { return }
        for peripheral in central.retrievePeripherals(withIdentifiers: ids) {
            peripheral.delegate = self
            connected[peripheral.identifier] = peripheral
            connectionStates[peripheral.identifier] = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    /// App backgrounded while not riding: drop sensor connections so we aren't
    /// kept alive in the background processing their BLE streams. Auto-reconnect
    /// is gated off (see didDisconnect) until `resumeFromBackground`.
    func suspendForBackground() {
        guard !backgroundSuspended else { return }
        // While monitoring for left-on sensors, keep them connected so we can
        // detect it and remind (bounded to 5 min by the reminder itself).
        if sensorMonitorStartedAt != nil, !sensorReminderSent { return }
        backgroundSuspended = true
        stopScan()
        radarKeepAliveTimer?.invalidate()
        radarKeepAliveTimer = nil
        for (id, peripheral) in connected {
            central.cancelPeripheralConnection(peripheral)
            connectionStates[id] = .retrying   // shows "reconnecting" until resumed
        }
    }

    /// Back in the foreground: reconnect the saved sensors.
    func resumeFromBackground() {
        guard backgroundSuspended else { return }
        backgroundSuspended = false
        reconnectSavedDevices()
    }

    // MARK: - "Sensors left on" reminder

    /// Begin watching, after a ride, whether the sensors get left switched on.
    /// No-op if nothing is connected (nothing to leave on).
    func beginSensorMonitor() {
        // Only worth keeping sensors alive to watch them if we can actually remind.
        guard NotificationManager.shared.isAuthorized,
              !connectedSensorNames().isEmpty else { sensorMonitorStartedAt = nil; return }
        sensorMonitorStartedAt = Date()
        sensorReminderSent = false
    }

    func cancelSensorMonitor() {
        sensorMonitorStartedAt = nil
        sensorReminderSent = false
    }

    /// Called from the sensor data stream (so it only runs while a sensor is
    /// actually on and feeding us). Once 5 min have passed with a sensor still
    /// connected, remind the rider and drop the connections.
    private func checkSensorReminder() {
        guard let startedAt = sensorMonitorStartedAt, !sensorReminderSent,
              Date().timeIntervalSince(startedAt) >= BluetoothManager.sensorReminderDelay else { return }
        let names = connectedSensorNames()
        sensorMonitorStartedAt = nil
        guard !names.isEmpty else { return }
        sensorReminderSent = true
        NotificationManager.shared.notifySensorsLeftOn(names)
        // They've been reminded — stop the background drain by dropping them.
        if UIApplication.shared.applicationState != .active { suspendForBackground() }
    }

    /// Human role names of sensors currently connected (e.g. ["Radar", "Cadence"]).
    private func connectedSensorNames() -> [String] {
        var roles = Set<DeviceRole>()
        for dev in savedDevices where connectionStates[dev.id] == .connected {
            dev.roles.forEach { roles.insert($0) }
        }
        return DeviceRole.allCases.filter { roles.contains($0) }.map(\.rawValue)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        poweredOn = central.state == .poweredOn
        if poweredOn { reconnectSavedDevices() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoveredPeripherals[peripheral.identifier] = peripheral

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard let name, !name.isEmpty else { return }

        // Radar is identifiable from its advertised service; speed vs cadence
        // can only be told apart once the CSC sensor reports data.
        var roles: Set<DeviceRole> = []
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           services.contains(BluetoothManager.radarService) {
            roles.insert(.radar)
        }

        let device = DiscoveredDevice(id: peripheral.identifier, name: name,
                                      rssi: RSSI.intValue, roles: roles)
        if let idx = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[idx].rssi = device.rssi
            discovered[idx].roles.formUnion(roles)
        } else {
            discovered.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStates[peripheral.identifier] = .connected
        lastDataAt[peripheral.identifier] = Date()   // grace period before liveness applies
        upsertSavedDevice(id: peripheral.identifier, name: peripheral.name ?? "")
        diag("Connected: \(peripheral.name ?? "?")")
        peripheral.discoverServices(nil)   // discover everything, match by UUID below
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        clearRadarControl(for: peripheral.identifier)   // re-armed on re-discovery
        lastRadarFrameAt[peripheral.identifier] = nil   // require fresh frames after reconnect
        if (peripheral.services ?? []).contains(where: {
            BluetoothManager.radarServiceUUIDs.contains($0.uuid)
        }) {
            radarBatteryPercent = nil   // unknown until the radar reconnects
        }
        recomputeRadarThreatsIfNeeded()
        // Auto-reconnect remembered devices indefinitely (sensors drop in/out a
        // lot) — unless we deliberately backgrounded; then wait for resume.
        if savedDevices.contains(where: { $0.id == peripheral.identifier }) {
            connectionStates[peripheral.identifier] = .retrying
            if !backgroundSuspended { central.connect(peripheral, options: nil) }
        } else {
            connectionStates[peripheral.identifier] = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if savedDevices.contains(where: { $0.id == peripheral.identifier }) {
            connectionStates[peripheral.identifier] = .retrying
            if !backgroundSuspended { central.connect(peripheral, options: nil) }   // keep trying
        } else {
            connectionStates[peripheral.identifier] = nil
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            diag("Service \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                   error: Error?) {
        // The TR70 radar identifies itself by its proprietary FDB0 service.
        if service.uuid == BluetoothManager.coospoRadarService {
            upsertSavedDevice(id: peripheral.identifier, name: peripheral.name ?? "", addRole: .radar)
        }
        // A radar speaking a proprietary protocol (e.g. the TR70) streams its
        // threat data over a vendor characteristic we can't name in advance, so
        // on a radar peripheral we subscribe to *every* notify characteristic and
        // log the raw bytes — that's the only way to capture and decode it.
        let isRadarPeripheral = (peripheral.services ?? []).contains {
            BluetoothManager.radarServiceUUIDs.contains($0.uuid)
        }
        for ch in service.characteristics ?? [] {
            let notify = ch.properties.contains(.notify) || ch.properties.contains(.indicate)
            diag("  char \(ch.uuid.uuidString)\(notify ? " [notify]" : "")")
            if BluetoothManager.radarMeasurementUUIDs.contains(ch.uuid) {
                peripheral.setNotifyValue(true, for: ch)
                upsertSavedDevice(id: peripheral.identifier, name: peripheral.name ?? "", addRole: .radar)
                diag("  → subscribed RADAR")
            } else if ch.uuid == BluetoothManager.cscMeasurement {
                peripheral.setNotifyValue(true, for: ch)
                diag("  → subscribed CSC")
            } else if ch.uuid == BluetoothManager.coospoRadarControl {
                // The TR70 stays silent until poked here, and won't detect cars
                // until it's put into active mode (the activate command).
                radarControlChars[peripheral.identifier] = ch
                diag("  → radar control FDB2 ready")
                peripheral.writeValue(BluetoothManager.coospoRadarActivateCommand,
                                      for: ch, type: .withoutResponse)   // active mode
                pokeRadar()              // enable…
                startRadarKeepAlive()    // …then keep it alive
            } else if ch.uuid == BluetoothManager.batteryLevel, isRadarPeripheral {
                peripheral.setNotifyValue(true, for: ch)   // battery-change updates
                peripheral.readValue(for: ch)              // initial level
                diag("  → radar battery")
            } else if notify, isRadarPeripheral {
                // Proprietary radar characteristic — subscribe and capture raw
                // bytes so a ride past a car records the protocol to decode.
                peripheral.setNotifyValue(true, for: ch)
                diag("  → capturing \(ch.uuid.uuidString)")
            }
        }
    }

    // MARK: - Coospo radar keepalive

    /// Write the "radar on" command to every connected radar's FDB2 control
    /// characteristic. The TR70 only streams on FDB1 while it's being poked.
    private func pokeRadar() {
        for (id, ch) in radarControlChars {
            guard let peripheral = connected[id], peripheral.state == .connected else { continue }
            peripheral.writeValue(BluetoothManager.coospoRadarEnableCommand, for: ch,
                                  type: .withoutResponse)
        }
    }

    private func startRadarKeepAlive() {
        guard radarKeepAliveTimer == nil else { return }
        radarKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pokeRadar()
        }
    }

    /// Drop a radar's control char on disconnect and stop the keepalive once no
    /// radar remains, so we're not writing into a dead peripheral.
    private func clearRadarControl(for id: UUID) {
        radarControlChars[id] = nil
        if radarControlChars.isEmpty {
            radarKeepAliveTimer?.invalidate()
            radarKeepAliveTimer = nil
        }
    }

    /// Confirms whether a notify subscription actually took, so a silent radar
    /// (device sending nothing) can be told apart from a failed subscribe.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                   error: Error?) {
        if let error {
            diag("  ✗ notify \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        } else {
            diag("  ✓ notify \(characteristic.uuid.uuidString) on=\(characteristic.isNotifying)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                   error: Error?) {
        guard let data = characteristic.value else { return }
        // Any data = the sensor is alive; refresh liveness and restore connected.
        lastDataAt[peripheral.identifier] = Date()
        if connectionStates[peripheral.identifier] == .retrying {
            connectionStates[peripheral.identifier] = .connected
        }
        checkSensorReminder()   // sensor still streaming after a ride? maybe remind
        if characteristic.uuid == BluetoothManager.batteryLevel {
            if let level = data.first,
               (peripheral.services ?? []).contains(where: {
                   BluetoothManager.radarServiceUUIDs.contains($0.uuid)
               }) {
                radarBatteryPercent = Int(level)
            }
            return
        }
        if BluetoothManager.radarMeasurementUUIDs.contains(characteristic.uuid) {
            parseRadar(data)
            lastRadarFrameAt[peripheral.identifier] = Date()
            return
        }
        if characteristic.uuid == BluetoothManager.cscMeasurement {
            parseCSC(data, from: peripheral.identifier)
            return
        }
        // The TR70 streams radar frames on FDB1 (its FDB0-service data char).
        // Decode them; always also log the raw bytes (throttled per UUID) so the
        // threat layout can be confirmed/refined from a ride.
        if characteristic.uuid == BluetoothManager.coospoRadarData {
            // Only a *valid* frame (heartbeat or threat page) counts as the radar
            // streaming — a bare reconnect with no real data must not read green.
            if parseCoospoRadar(data) { lastRadarFrameAt[peripheral.identifier] = Date() }
        }
        captureLog(characteristic.uuid, peripheral.name ?? "?", data)
    }

    // MARK: - Helpers

    // Logs raw bytes from unknown notify characteristics (throttled per UUID) so
    // the TR70's radar protocol can be decoded from a real ride. This writes to
    // disk ~1×/second for the WHOLE ride, so it's gated behind the radar-debug
    // toggle — off for normal riders (battery), on when capturing for protocol work.
    private var lastCaptureAt: [CBUUID: Date] = [:]
    private func captureLog(_ uuid: CBUUID, _ name: String, _ data: Data) {
        guard settings.radarDebugEnabled else { return }
        let now = Date()
        if let last = lastCaptureAt[uuid], now.timeIntervalSince(last) < 1.0 { return }
        lastCaptureAt[uuid] = now
        let hex = [UInt8](data).map { String(format: "%02x", $0) }.joined(separator: " ")
        diag("CAP \(name) \(uuid.uuidString) \(data.count)B: \(hex)")
    }

    private func recomputeRadarThreatsIfNeeded() {
        // If no radar is actively connected, clear the lane.
        let radarConnected = connected.values.contains { p in
            p.state == .connected && (p.services ?? []).contains {
                BluetoothManager.radarServiceUUIDs.contains($0.uuid)
            }
        }
        if !radarConnected && !demoActive { threats = [] }
    }

    // MARK: - Radar parsing
    //
    // Payload = 1 page/counter byte, then 3 bytes per threat:
    //   [threat id][distance in metres][approach speed in km/h]

    @Published private(set) var radarPacketCount = 0
    @Published private(set) var lastRadarHex = ""
    private var lastRadarLogAt: Date?

    /// Number of manual "a car just passed" marks the rider has logged this run.
    @Published private(set) var carMarkCount = 0

    /// Rider taps this when a real car passes, dropping a timestamped, greppable
    /// line into the log so sparse car events can be lined up against captured
    /// radar packets when decoding the TR70's proprietary protocol. Logging the
    /// current packet count/last hex makes it obvious whether the radar sent
    /// anything at the moment the car went by.
    func markCarObserved() {
        carMarkCount += 1
        let hex = lastRadarHex.isEmpty ? "(no radar packets yet)" : lastRadarHex
        diag("CAR MARK #\(carMarkCount) — radarPackets=\(radarPacketCount) lastHex=\(hex)")
    }

    private func parseRadar(_ data: Data) {
        guard !demoActive else { return }
        let bytes = [UInt8](data)
        radarPacketCount += 1
        lastRadarHex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")

        // Throttled radar logging so a diagnostics run captures real packets.
        let now = Date()
        if lastRadarLogAt == nil || now.timeIntervalSince(lastRadarLogAt!) >= 3 {
            lastRadarLogAt = now
            AppLog.shared.log("RADAR rx #\(radarPacketCount) \(bytes.count)B: \(lastRadarHex)")
        }

        var newThreats: [Threat] = []
        var i = 1
        while i + 3 <= bytes.count {
            let id = Int(bytes[i])
            let distance = Double(bytes[i + 1])
            let speed = Double(bytes[i + 2])
            if !(id == 0 && distance == 0) {
                newThreats.append(Threat(id: id, distanceMeters: distance,
                                         approachSpeedKmh: speed, lastSeen: Date()))
            }
            i += 3
        }
        applyThreats(newThreats)
    }

    /// Decode a TR70 FDB1 radar frame, captured from CoospoRide:
    ///   [0xC8][len][page][payload…][checksum]
    /// where `len` is the whole-frame length and `checksum` = sum of all prior
    /// bytes & 0xFF (verified against real packets). Page 0x24 is the threat
    /// page; other pages (e.g. 0x03 status/heartbeat, 0x05 keepalive ack) carry
    /// no threats and are ignored.
    ///
    /// Page 0x24 layout, decoded from real rides/walks past traffic. The frame
    /// carries a payload of fixed-size target blocks between the 3-byte header
    /// ([0xC8][len][page]) and the trailing checksum. Every capture so far is a
    /// single 14-byte block (an 18-byte frame) reporting the nearest target:
    ///   block[0]  (frame byte 3)  = the radar's own threat level (0 = none)
    ///   block[6]  (frame byte 9)  = distance in metres (counts down on approach)
    ///   block[10] (frame byte 13) = approach speed in metres per second
    /// All-zero (distance 0) means the road is clear.
    ///
    /// Multi-car is SPECULATIVE: across every capture the TR70 has only ever sent
    /// one block, so we have no real two-car frame to confirm a second slot's
    /// position. We therefore parse the payload as *repeating 14-byte blocks
    /// driven by the frame length* — for the known 18-byte frame this is
    /// byte-for-byte identical to single-target decoding (one block), and only a
    /// genuinely longer frame would surface extra targets. Each extra block is
    /// sanity-bounded so a malformed/garbage frame can't render phantom cars.
    private static let radarBlockSize = 14
    @discardableResult
    private func parseCoospoRadar(_ data: Data) -> Bool {
        guard !demoActive else { return false }
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xC8, Int(bytes[1]) == bytes.count else { return false }
        let checksum = bytes.dropLast().reduce(0) { $0 + Int($1) } & 0xFF
        guard checksum == Int(bytes[bytes.count - 1]) else { return false }

        // Valid frame ⇒ the radar is alive and streaming.
        radarPacketCount += 1
        lastRadarHex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")

        guard bytes[2] == BluetoothManager.coospoRadarThreatPage, bytes.count >= 18 else { return true }

        // Payload sits between the 3-byte header and the 1-byte checksum.
        let payload = Array(bytes[3 ..< bytes.count - 1])
        var parsed: [Threat] = []
        var off = 0
        while off + BluetoothManager.radarBlockSize <= payload.count {
            let distanceM = Double(payload[off + 6])
            let speedKmh = Double(payload[off + 10]) * 3.6
            // Sanity bounds: a real rear-radar target is within range and below a
            // plausible closing speed. Slot 0 with distance 0 is "road clear".
            if distanceM >= 1, distanceM <= 200, speedKmh <= 160 {
                parsed.append(Threat(id: off / BluetoothManager.radarBlockSize,
                                     distanceMeters: distanceM,
                                     approachSpeedKmh: speedKmh, lastSeen: Date()))
            }
            off += BluetoothManager.radarBlockSize
        }

        guard !parsed.isEmpty else { applyThreats([]); return true }   // road clear

        // A real target — log every such frame so the protocol stays verifiable.
        // (Frames > 18 bytes would prove a real multi-car slot; flag them loudly.)
        let tag = bytes.count > 18 ? "MULTI \(parsed.count)" : "threat"
        AppLog.shared.log("RADAR FDB1 \(tag) \(bytes.count)B: \(lastRadarHex)")
        applyThreats(parsed)
        return true
    }

    /// Shared threat pipeline used by both the radar and demo mode: detect new
    /// cars (previously-unseen ids), beep once, and publish the sorted list.
    private func applyThreats(_ incoming: [Threat]) {
        let sorted = incoming.sorted { $0.distanceMeters < $1.distanceMeters }
        let existingIDs = Set(threats.map(\.id))
        let hasNewCar = sorted.contains { !existingIDs.contains($0.id) }
        threats = sorted
        if hasNewCar, alertsAllowed?() ?? true {
            if settings.beepEnabled { AudioAlerts.shared.playNewCar() }
            onNewCar?()
        }
    }

    // MARK: - Demo mode
    //
    // Cycles through scripted frames so the rider can preview what low / medium
    // / high threats look (and sound) like, started from the Settings screen.

    private var demoTimer: Timer?
    private var demoStep = 0

    /// Called when the radar demo finishes its single pass, so the metrics demo
    /// can stop in step with it.
    var onDemoFinished: (() -> Void)?

    /// Called when a *new* vehicle is detected (for the Watch wrist haptic).
    var onNewCar: (() -> Void)?

    /// Gate for new-vehicle alerts (beep + wrist haptic): the radar streams
    /// whenever it's connected, but we only want to alert during an actual ride
    /// (or the demo), not while the app sits idle with the radar on. Supplied by
    /// RideManager; defaults to allowing alerts if unset.
    var alertsAllowed: (() -> Bool)?

    // (id, distance m, approach speed km/h) → level is derived in Threat.level.
    // One car approaching through all three threat levels, scaled to the ~50 m
    // lane: far (yellow) → mid (orange) → close (red) → clear.
    private let demoFrames: [[(Int, Double, Double)]] = [
        [(1, 46, 10)],     // far → LOW (yellow)
        [(1, 36, 13)],     // closing
        [(1, 26, 18)],     // MEDIUM (orange)
        [(1, 17, 24)],     // closer
        [(1, 9, 30)],      // HIGH (red)
        []                 // CLEAR
    ]

    private var demoPaused = false

    func startDemo() {
        stopScan()
        demoActive = true
        demoPaused = false
        demoStep = 0
        threats = []
        tickDemo()
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            self?.tickDemo()
        }
    }

    func stopDemo() {
        demoActive = false
        demoPaused = false
        demoTimer?.invalidate()
        demoTimer = nil
        threats = []
        cadenceRpm = nil          // clear so the tile resets immediately
        cadenceUpdatedAt = nil
    }

    func setDemoPaused(_ paused: Bool) { demoPaused = paused }

    private func tickDemo() {
        // While paused, freeze the radar/cadence but keep the value fresh.
        guard !demoPaused else { cadenceUpdatedAt = Date(); return }

        // Keep a realistic cadence flowing for the duration of the demo.
        cadenceRpm = Int.random(in: 78...96)
        cadenceUpdatedAt = Date()

        // Run once through the sequence, then stop on the final (clear) frame.
        guard demoStep < demoFrames.count else {
            // Stop the radar side (so the phone shows the radar-off preview) but
            // leave the cadence value fresh — it was just set above, so its 4 s
            // freshness window covers the ride's ~3.5 s radar-off tail and the
            // Cadence tile keeps showing instead of flashing "—" at the end.
            demoActive = false
            demoPaused = false
            demoTimer?.invalidate()
            demoTimer = nil
            threats = []
            onDemoFinished?()
            return
        }
        let frame = demoFrames[demoStep]
        demoStep += 1
        let now = Date()
        applyThreats(frame.map { Threat(id: $0.0, distanceMeters: $0.1,
                                        approachSpeedKmh: $0.2, lastSeen: now) })
    }

    // MARK: - CSC parsing (speed & cadence)

    private func parseCSC(_ data: Data, from id: UUID) {
        let bytes = [UInt8](data)
        guard bytes.count >= 1 else { return }
        let flags = bytes[0]
        let wheelPresent = flags & 0x01 != 0
        let crankPresent = flags & 0x02 != 0
        var idx = 1

        // Tag this device with what it actually reports, so the Speed and
        // Cadence status pills reflect the real sensor(s).
        if wheelPresent { markCapability(.speed, for: id) }
        if crankPresent { markCapability(.cadence, for: id) }

        func readU16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8) }
        func readU32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) |
            (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        }

        if wheelPresent, bytes.count >= idx + 6 {
            let revs = readU32(idx); idx += 4
            let eventTime = readU16(idx); idx += 2   // 1/1024 s units
            if let lastRevs = lastWheelRevs, let lastTime = lastWheelEventTime {
                let dRevs = revs &- lastRevs
                let dTime = eventTime &- lastTime
                if dTime > 0 && dRevs < 1_000_000 {
                    let seconds = Double(dTime) / 1024.0
                    let distance = Double(dRevs) * settings.wheelCircumferenceMeters
                    sensorSpeedMps = distance / seconds
                    sensorSpeedUpdatedAt = Date()
                } else if dRevs == 0 {
                    sensorSpeedMps = 0
                    sensorSpeedUpdatedAt = Date()
                }
            }
            lastWheelRevs = revs
            lastWheelEventTime = eventTime
        }

        if crankPresent, bytes.count >= idx + 4 {
            let revs = readU16(idx); idx += 2
            let eventTime = readU16(idx); idx += 2
            if let lastRevs = lastCrankRevs, let lastTime = lastCrankEventTime {
                let dRevs = revs &- lastRevs
                let dTime = eventTime &- lastTime
                if dTime > 0 {
                    let minutes = Double(dTime) / 1024.0 / 60.0
                    cadenceRpm = Int((Double(dRevs) / minutes).rounded())
                    cadenceUpdatedAt = Date()
                } else if dRevs == 0 {
                    cadenceRpm = 0
                    cadenceUpdatedAt = Date()
                }
            }
            lastCrankRevs = revs
            lastCrankEventTime = eventTime
        }
    }

    func freshSensorSpeed(staleAfter seconds: TimeInterval = 4) -> Double? {
        guard let speed = sensorSpeedMps, let at = sensorSpeedUpdatedAt else { return nil }
        return Date().timeIntervalSince(at) <= seconds ? speed : nil
    }

    var freshCadence: Int? {
        guard let cadence = cadenceRpm, let at = cadenceUpdatedAt else { return nil }
        return Date().timeIntervalSince(at) <= 4 ? cadence : nil
    }
}
