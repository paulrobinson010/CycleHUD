import Foundation
import CoreBluetooth
import SwiftUI
import Combine

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
        case .connecting, .retrying: return Theme.threatLow
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
    static let radarServiceUUIDs: Set<CBUUID> = [radarService, radarServiceAlt]
    static let cscService = CBUUID(string: "1816")
    static let cscMeasurement = CBUUID(string: "2A5B")
    private let savedDevicesKey = "savedDevicesV3"

    // MARK: Published state

    @Published private(set) var poweredOn = false
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredDevice] = []

    @Published private(set) var savedDevices: [SavedDevice] = []
    @Published private(set) var connectionStates: [UUID: ConnectionState] = [:]

    @Published private(set) var threats: [Threat] = []
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
    }

    // MARK: - Role / device status (for the main-screen icons)

    func status(for role: DeviceRole) -> RoleStatus {
        if demoActive { return .connected }   // demo: show everything live
        let matching = savedDevices.filter { $0.roles.contains(role) }
        guard !matching.isEmpty else { return .notConfigured }
        if !poweredOn { return .failed }
        let states = matching.map { connectionStates[$0.id] ?? .retrying }
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) { return .connecting }
        return .retrying
    }

    func deviceState(_ id: UUID) -> ConnectionState {
        connectionStates[id] ?? .retrying
    }

    // MARK: - Scanning / pairing

    func startScan() {
        guard poweredOn else { return }
        discovered.removeAll()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScan() {
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
        upsertSavedDevice(id: peripheral.identifier, name: peripheral.name ?? "")
        diag("Connected: \(peripheral.name ?? "?")")
        peripheral.discoverServices(nil)   // discover everything, match by UUID below
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        recomputeRadarThreatsIfNeeded()
        // Auto-reconnect remembered devices indefinitely (sensors drop in/out a lot).
        if savedDevices.contains(where: { $0.id == peripheral.identifier }) {
            connectionStates[peripheral.identifier] = .retrying
            central.connect(peripheral, options: nil)
        } else {
            connectionStates[peripheral.identifier] = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if savedDevices.contains(where: { $0.id == peripheral.identifier }) {
            connectionStates[peripheral.identifier] = .retrying
            central.connect(peripheral, options: nil)   // keep trying
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
        for ch in service.characteristics ?? [] {
            let notify = ch.properties.contains(.notify) || ch.properties.contains(.indicate)
            diag("  char \(ch.uuid.uuidString)\(notify ? " [notify]" : "")")
            if BluetoothManager.radarMeasurementUUIDs.contains(ch.uuid) {
                peripheral.setNotifyValue(true, for: ch)
                upsertSavedDevice(id: peripheral.identifier, name: peripheral.name ?? "", addRole: .radar)
                diag("  → subscribed RADAR")
            } else if ch.uuid == BluetoothManager.cscMeasurement {
                // Speed / cadence roles are assigned once we see the data flags.
                peripheral.setNotifyValue(true, for: ch)
                diag("  → subscribed CSC")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                   error: Error?) {
        guard let data = characteristic.value else { return }
        if BluetoothManager.radarMeasurementUUIDs.contains(characteristic.uuid) {
            parseRadar(data)
            return
        }
        switch characteristic.uuid {
        case BluetoothManager.cscMeasurement: parseCSC(data, from: peripheral.identifier)
        default: break
        }
    }

    // MARK: - Helpers

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

    /// Shared threat pipeline used by both the radar and demo mode: detect new
    /// cars (previously-unseen ids), beep once, and publish the sorted list.
    private func applyThreats(_ incoming: [Threat]) {
        let sorted = incoming.sorted { $0.distanceMeters < $1.distanceMeters }
        let existingIDs = Set(threats.map(\.id))
        let hasNewCar = sorted.contains { !existingIDs.contains($0.id) }
        threats = sorted
        if hasNewCar {
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

    // (id, distance m, approach speed km/h) → level is derived in Threat.level.
    private let demoFrames: [[(Int, Double, Double)]] = [
        [(1, 135, 18)],                                   // single car, far → LOW (yellow)
        [(1, 95, 20)],                                    // closing in
        [(2, 60, 32)],                                    // MEDIUM (orange)
        [(3, 22, 52)],                                    // HIGH (red)
        [(4, 140, 16), (5, 68, 30), (6, 18, 56)],         // all three levels at once
        []                                                // CLEAR
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
            stopDemo()
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
