import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

/// All mutable CoreBluetooth state is confined to the main actor.
final class CoreBluetoothAdapter: NSObject, BluetoothTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let logger: BluetoothLogging
    private var central: CBCentralManager!
    private var scanContinuation: AsyncThrowingStream<BluetoothDevice, Error>.Continuation?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connections: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var connectionTimeouts: [UUID: Task<Void, Never>] = [:]
    private let connectionTimeoutSeconds: UInt64 = 12
    private var serviceRequests: [UUID: CheckedContinuation<[GATTService], Error>] = [:]
    private var characteristicRequests: [String: CheckedContinuation<[GATTCharacteristic], Error>] = [:]
    private var readRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var writeRequests: [String: CheckedContinuation<Void, Error>] = [:]
    private var streams: [String: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var gattTimeouts: [String: Task<Void, Never>] = [:]
    private let gattTimeoutSeconds: UInt64 = 10
    private var stateObservers: [UUID: AsyncStream<BluetoothState>.Continuation] = [:]

    nonisolated func stateEvents() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            let token = UUID()
            Task { @MainActor in
                self.stateObservers[token] = continuation
                continuation.yield(await self.state)
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in self.stateObservers.removeValue(forKey: token) }
                }
            }
        }
    }

    private func startGATTTimeout(_ key: String, onTimeout: @escaping @MainActor () -> Void) {
        gattTimeouts[key]?.cancel()
        gattTimeouts[key] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: (self?.gattTimeoutSeconds ?? 10) * 1_000_000_000) }
            catch { return }
            guard let self else { return }
            self.gattTimeouts.removeValue(forKey: key)
            onTimeout()
        }
    }
    private func cancelGATTTimeout(_ key: String) {
        gattTimeouts.removeValue(forKey: key)?.cancel()
    }
    private func failPendingGATT(_ error: BluetoothError) {
        for (_, task) in gattTimeouts { task.cancel() }
        gattTimeouts.removeAll()
        for (_, request) in serviceRequests { request.resume(throwing: error) }
        serviceRequests.removeAll()
        for (_, request) in characteristicRequests { request.resume(throwing: error) }
        characteristicRequests.removeAll()
        for (_, request) in readRequests { request.resume(throwing: error) }
        readRequests.removeAll()
        for (_, request) in writeRequests { request.resume(throwing: error) }
        writeRequests.removeAll()
    }
    private var config: ScanConfiguration = .default
    private var eventObservers: [UUID: AsyncStream<ConnectionEvent>.Continuation] = [:]
    private var intentionallyDisconnected = Set<UUID>()
    private var reconnectPolicies: [UUID: ReconnectPolicy] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var notificationKeys: [UUID: Set<String>] = [:]
    private var restoringSubscriptions = Set<UUID>()

    nonisolated func connectionEvents() -> AsyncStream<ConnectionEvent> {
        AsyncStream { continuation in
            let token = UUID()
            Task { @MainActor in
                self.eventObservers[token] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in self.eventObservers.removeValue(forKey: token) }
                }
            }
        }
    }

    private func emit(_ id: UUID, _ state: ConnectionState) {
        let event = ConnectionEvent(deviceID: id, state: state)
        for observer in eventObservers.values { observer.yield(event) }
    }

    func setAutoReconnect(_ policy: ReconnectPolicy, for device: BluetoothDevice) {
        reconnectPolicies[device.id] = policy
        intentionallyDisconnected.remove(device.id)
    }

    func disableAutoReconnect(for device: BluetoothDevice) {
        reconnectPolicies.removeValue(forKey: device.id)
        reconnectTasks.removeValue(forKey: device.id)?.cancel()
    }


    init(logger: BluetoothLogging) {
        self.logger = logger
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var state: BluetoothState {
        get async {
            switch central.state {
            case .poweredOn: return .poweredOn
            case .poweredOff: return .poweredOff
            case .unauthorized: return .unauthorized
            case .unsupported: return .unsupported
            case .resetting: return .resetting
            default: return .unknown
            }
        }
    }

    private func stateError() -> BluetoothError {
        switch central.state {
        case .poweredOff: return .bluetoothPoweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        default: return .bluetoothUnavailable
        }
    }

    nonisolated func scan(configuration: ScanConfiguration) -> AsyncThrowingStream<BluetoothDevice, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard self.central.state == .poweredOn else { continuation.finish(throwing: self.stateError()); return }
                self.scanContinuation?.finish()
                self.scanContinuation = continuation
                self.config = configuration
                let services = configuration.serviceUUIDs.isEmpty ? nil : configuration.serviceUUIDs.map { CBUUID(nsuuid: $0) }
                self.central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: configuration.allowDuplicates])
                continuation.onTermination = { @Sendable _ in Task { @MainActor in self.central.stopScan() } }
            }
        }
    }

    func stopScan() async { central.stopScan(); scanContinuation?.finish(); scanContinuation = nil }

    func connect(to device: BluetoothDevice) async throws {
        guard central.state == .poweredOn else { throw stateError() }
        guard let p = peripherals[device.id] else { throw BluetoothError.deviceNotFound }
        if p.state == .connected { return }
        emit(device.id, .connecting)
        guard connections[device.id] == nil else { throw BluetoothError.connectionFailed }
        try await withCheckedThrowingContinuation { c in
            connections[device.id] = c
            central.connect(p)
            connectionTimeouts[device.id] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: (self?.connectionTimeoutSeconds ?? 12) * 1_000_000_000)
                guard let self, let pending = self.connections.removeValue(forKey: device.id) else { return }
                self.central.cancelPeripheralConnection(p)
                pending.resume(throwing: BluetoothError.timeout)
                self.connectionTimeouts.removeValue(forKey: device.id)
            }
        }
    }

    func disconnect(from device: BluetoothDevice) async {
        intentionallyDisconnected.insert(device.id)
        disableAutoReconnect(for: device)
        emit(device.id, .disconnecting)
        connectionTimeouts.removeValue(forKey: device.id)?.cancel()
        connections.removeValue(forKey: device.id)?.resume(throwing: BluetoothError.disconnected)
        if let p = peripherals[device.id] { central.cancelPeripheralConnection(p) }
    }

    private func connected(_ device: BluetoothDevice) throws -> CBPeripheral {
        guard let p = peripherals[device.id], p.state == .connected else { throw BluetoothError.disconnected }
        p.delegate = self
        return p
    }

    private func key(_ device: UUID, _ service: String, _ characteristic: String = "") -> String {
        "\(device.uuidString)|\(service.uppercased())|\(characteristic.uppercased())"
    }

    private func service(_ uuid: String, on p: CBPeripheral) throws -> CBService {
        guard let s = p.services?.first(where: { $0.uuid == CBUUID(string: uuid) }) else { throw BluetoothError.serviceNotFound(UUID(uuidString: uuid) ?? UUID()) }
        return s
    }

    private func characteristic(_ uuid: String, serviceUUID: String, on p: CBPeripheral) throws -> CBCharacteristic {
        let s = try service(serviceUUID, on: p)
        guard let c = s.characteristics?.first(where: { $0.uuid == CBUUID(string: uuid) }) else { throw BluetoothError.characteristicNotFound(UUID(uuidString: uuid) ?? UUID()) }
        return c
    }

    func discoverServices(on device: BluetoothDevice) async throws -> [GATTService] {
        let p = try connected(device)
        guard serviceRequests[device.id] == nil else { throw BluetoothError.scanningFailed }
        return try await withCheckedThrowingContinuation { c in serviceRequests[device.id] = c
            startGATTTimeout("service|\(device.id)") { [weak self] in self?.serviceRequests.removeValue(forKey: device.id)?.resume(throwing: BluetoothError.timeout) }
            p.discoverServices(nil) }
    }

    func discoverCharacteristics(serviceUUID: String, on device: BluetoothDevice) async throws -> [GATTCharacteristic] {
        let p = try connected(device), s = try service(serviceUUID, on: p)
        let k = key(device.id, serviceUUID)
        guard characteristicRequests[k] == nil else { throw BluetoothError.scanningFailed }
        return try await withCheckedThrowingContinuation { c in characteristicRequests[k] = c
            startGATTTimeout("characteristic|" + k) { [weak self] in self?.characteristicRequests.removeValue(forKey: k)?.resume(throwing: BluetoothError.timeout) }
            p.discoverCharacteristics(nil, for: s) }
    }

    func read(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) async throws -> Data {
        let p = try connected(device), c = try characteristic(characteristicUUID, serviceUUID: serviceUUID, on: p)
        guard c.properties.contains(.read) else { throw BluetoothError.readFailed }
        let k = key(device.id, serviceUUID, characteristicUUID)
        guard readRequests[k] == nil else { throw BluetoothError.readFailed }
        return try await withCheckedThrowingContinuation { continuation in readRequests[k] = continuation
            startGATTTimeout("read|" + k) { [weak self] in self?.readRequests.removeValue(forKey: k)?.resume(throwing: BluetoothError.timeout) }
            p.readValue(for: c) }
    }

    func write(_ data: Data, characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice, type: GATTWriteType) async throws {
        let p = try connected(device), c = try characteristic(characteristicUUID, serviceUUID: serviceUUID, on: p)
        let withResponse = type == .withResponse
        guard c.properties.contains(withResponse ? .write : .writeWithoutResponse) else { throw BluetoothError.writeFailed }
        guard data.count <= p.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse) else { throw BluetoothError.writeFailed }
        if !withResponse { p.writeValue(data, for: c, type: .withoutResponse); return }
        let k = key(device.id, serviceUUID, characteristicUUID)
        guard writeRequests[k] == nil else { throw BluetoothError.writeFailed }
        try await withCheckedThrowingContinuation { continuation in writeRequests[k] = continuation
            startGATTTimeout("write|" + k) { [weak self] in self?.writeRequests.removeValue(forKey: k)?.resume(throwing: BluetoothError.timeout) }
            p.writeValue(data, for: c, type: .withResponse) }
    }

    nonisolated func notifications(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let p = try self.connected(device)
                    let c = try self.characteristic(characteristicUUID, serviceUUID: serviceUUID, on: p)
                    guard c.properties.contains(.notify) || c.properties.contains(.indicate) else { throw BluetoothError.notificationFailed }
                    let k = self.key(device.id, serviceUUID, characteristicUUID)
                    guard self.streams[k] == nil else { throw BluetoothError.notificationFailed }
                    self.streams[k] = continuation
                    self.notificationKeys[device.id, default: []].insert(k)
                    p.setNotifyValue(true, for: c)
                    continuation.onTermination = { @Sendable _ in
                        Task { @MainActor in
                            self.streams.removeValue(forKey: k)
                            self.notificationKeys[device.id]?.remove(k)
                            if p.state == .connected { p.setNotifyValue(false, for: c) }
                        }
                    }
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let current: BluetoothState
        switch central.state {
        case .poweredOn: current = .poweredOn
        case .poweredOff: current = .poweredOff
        case .unauthorized: current = .unauthorized
        case .unsupported: current = .unsupported
        case .resetting: current = .resetting
        default: current = .unknown
        }
        for observer in stateObservers.values { observer.yield(current) }
        if central.state != .poweredOn {
            scanContinuation?.finish(throwing: stateError()); scanContinuation = nil
            failPendingGATT(stateError())
            for (_, pending) in connections { pending.resume(throwing: stateError()) }
            connections.removeAll()
            for (_, timeout) in connectionTimeouts { timeout.cancel() }
            connectionTimeouts.removeAll()
            for (_, task) in reconnectTasks { task.cancel() }
            reconnectTasks.removeAll()
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[p.identifier] = p
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).compactMap { UUID(uuidString: $0.uuidString) }
        let d = BluetoothDevice(id: p.identifier, name: p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String, rssi: RSSI.intValue, advertisedServiceUUIDs: services, manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        if DeviceFilter().matches(d, configuration: config) { scanContinuation?.yield(d) }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        connectionTimeouts.removeValue(forKey: p.identifier)?.cancel()
        p.delegate = self
        emit(p.identifier, .connected)
        connections.removeValue(forKey: p.identifier)?.resume()
        if notificationKeys[p.identifier]?.isEmpty == false {
            restoringSubscriptions.insert(p.identifier)
            p.discoverServices(nil)
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connectionTimeouts.removeValue(forKey: p.identifier)?.cancel()
        emit(p.identifier, .failed(error?.localizedDescription ?? "Connection failed"))
        connections.removeValue(forKey: p.identifier)?.resume(throwing: BluetoothError.connectionFailed)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connectionTimeouts.removeValue(forKey: p.identifier)?.cancel()
        connections.removeValue(forKey: p.identifier)?.resume(throwing: BluetoothError.disconnected)
        cancelGATTTimeout("service|\(p.identifier)")
        serviceRequests.removeValue(forKey: p.identifier)?.resume(throwing: BluetoothError.disconnected)
        for k in characteristicRequests.keys.filter({ $0.hasPrefix(p.identifier.uuidString + "|") }) { cancelGATTTimeout("characteristic|" + k); characteristicRequests.removeValue(forKey: k)?.resume(throwing: BluetoothError.disconnected) }
        for k in readRequests.keys.filter({ $0.hasPrefix(p.identifier.uuidString + "|") }) { cancelGATTTimeout("read|" + k); readRequests.removeValue(forKey: k)?.resume(throwing: BluetoothError.disconnected) }
        for k in writeRequests.keys.filter({ $0.hasPrefix(p.identifier.uuidString + "|") }) { cancelGATTTimeout("write|" + k); writeRequests.removeValue(forKey: k)?.resume(throwing: BluetoothError.disconnected) }
        emit(p.identifier, .disconnected)
        let expected = intentionallyDisconnected.remove(p.identifier) != nil
        if expected || reconnectPolicies[p.identifier] == nil {
            for k in streams.keys.filter({ $0.hasPrefix(p.identifier.uuidString + "|") }) {
                streams.removeValue(forKey: k)?.finish(throwing: BluetoothError.disconnected)
            }
            notificationKeys.removeValue(forKey: p.identifier)
        } else if let policy = reconnectPolicies[p.identifier], reconnectTasks[p.identifier] == nil {
            reconnectTasks[p.identifier] = Task { @MainActor [weak self] in
                guard let self, let device = self.cachedDevice(p.identifier) else { return }
                do { try await self.connectWithRetry(device, policy: policy) }
                catch {
                    self.emit(p.identifier, .failed("Auto-reconnect exhausted: \(error.localizedDescription)"))
                    for k in self.streams.keys.filter({ $0.hasPrefix(p.identifier.uuidString + "|") }) {
                        self.streams.removeValue(forKey: k)?.finish(throwing: error)
                    }
                    self.notificationKeys.removeValue(forKey: p.identifier)
                }
                self.reconnectTasks.removeValue(forKey: p.identifier)
            }
        }
    }
    private func cachedDevice(_ id: UUID) -> BluetoothDevice? {
        guard let p = peripherals[id] else { return nil }
        return BluetoothDevice(id: id, name: p.name, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil)
    }

    private func connectWithRetry(_ device: BluetoothDevice, policy: ReconnectPolicy) async throws {
        let attempts: Int
        switch policy {
        case .disabled: attempts = 1
        case .immediate(let n), .exponentialBackoff(let n, _): attempts = max(1, n + 1)
        }
        for index in 0..<attempts {
            try Task.checkCancellation()
            do { try await connect(to: device); return }
            catch {
                guard index + 1 < attempts else { throw error }
                let seconds: Double
                switch policy {
                case .disabled, .immediate: seconds = 0
                case .exponentialBackoff(_, let delay): seconds = min(60, max(0, delay) * pow(2, Double(index)))
                }
                if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if restoringSubscriptions.contains(p.identifier) {
            if error == nil {
                for service in p.services ?? [] where notificationKeys[p.identifier]?.contains(where: { $0.hasPrefix(self.key(p.identifier, service.uuid.uuidString) + "|") }) == true {
                    p.discoverCharacteristics(nil, for: service)
                }
            } else { restoringSubscriptions.remove(p.identifier) }
        }
        cancelGATTTimeout("service|\(p.identifier)")
        guard let c = serviceRequests.removeValue(forKey: p.identifier) else { return }
        if let error { c.resume(throwing: error) } else { c.resume(returning: (p.services ?? []).map { GATTService(uuid: $0.uuid.uuidString, isPrimary: $0.isPrimary) }) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if restoringSubscriptions.contains(p.identifier), error == nil {
            for characteristic in s.characteristics ?? [] {
                let k = key(p.identifier, s.uuid.uuidString, characteristic.uuid.uuidString)
                if notificationKeys[p.identifier]?.contains(k) == true { p.setNotifyValue(true, for: characteristic) }
            }
        }
        cancelGATTTimeout("characteristic|" + key(p.identifier, s.uuid.uuidString))
        guard let c = characteristicRequests.removeValue(forKey: key(p.identifier, s.uuid.uuidString)) else { return }
        if let error { c.resume(throwing: error) } else {
            c.resume(returning: (s.characteristics ?? []).map { ch in
                var props: CharacteristicProperties = []
                if ch.properties.contains(.read) { props.insert(.read) }
                if ch.properties.contains(.write) { props.insert(.write) }
                if ch.properties.contains(.writeWithoutResponse) { props.insert(.writeWithoutResponse) }
                if ch.properties.contains(.notify) { props.insert(.notify) }
                if ch.properties.contains(.indicate) { props.insert(.indicate) }
                return GATTCharacteristic(uuid: ch.uuid.uuidString, serviceUUID: s.uuid.uuidString, properties: props)
            })
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let service_string = c.service?.uuid.uuidString else { return }
        let k = key(p.identifier,service_string , c.uuid.uuidString)
        cancelGATTTimeout("read|" + k)
        if let request = readRequests.removeValue(forKey: k) {
            if let error { request.resume(throwing: error) }
            else if let data = c.value { request.resume(returning: data) }
            else { request.resume(throwing: BluetoothError.readFailed) }
        }
        if let stream = streams[k] {
            if let error { stream.finish(throwing: error); streams.removeValue(forKey: k) }
            else if let data = c.value { stream.yield(data) }
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard let service_string = c.service?.uuid.uuidString else { return }
        let k = key(p.identifier, service_string, c.uuid.uuidString)
        cancelGATTTimeout("write|" + k)
        guard let request = writeRequests.removeValue(forKey: k) else { return }
        if let error { request.resume(throwing: error) } else { request.resume() }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard let service_string = c.service?.uuid.uuidString else { return }
        if let error {
            let k = key(p.identifier, service_string, c.uuid.uuidString)
            streams.removeValue(forKey: k)?.finish(throwing: error)
        }
    }
}
#endif
