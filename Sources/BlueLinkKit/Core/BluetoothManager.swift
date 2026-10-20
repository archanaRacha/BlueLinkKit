import Foundation

public final class BluetoothManager: @unchecked Sendable {
    private let transport: BluetoothTransport
    private let logger: BluetoothLogging

    public convenience init(logger: BluetoothLogging = NoopBluetoothLogger()) {
        #if canImport(CoreBluetooth)
        self.init(transport: CoreBluetoothAdapter(logger: logger), logger: logger)
        #else
        self.init(transport: UnsupportedBluetoothTransport(), logger: logger)
        #endif
    }

    init(transport: BluetoothTransport, logger: BluetoothLogging = NoopBluetoothLogger()) {
        self.transport = transport
        self.logger = logger
    }

    /// Observe Bluetooth power and authorization changes.
    public func stateEvents() -> AsyncStream<BluetoothState> { transport.stateEvents() }

    /// Observe connection changes, including unexpected disconnections.
    public func connectionEvents() -> AsyncStream<ConnectionEvent> { transport.connectionEvents() }

    /// Enable reconnect after an established link drops. Configure before connecting.
    public func enableAutoReconnect(for device: BluetoothDevice, policy: ReconnectPolicy = .exponentialBackoff(maxAttempts: 3, initialDelay: 1)) async {
        await transport.setAutoReconnect(policy, for: device)
    }

    public func disableAutoReconnect(for device: BluetoothDevice) async {
        await transport.disableAutoReconnect(for: device)
    }

    public var state: BluetoothState {
        get async { await transport.state }
    }

    public func scan(
        configuration: ScanConfiguration = .default
    ) -> AsyncThrowingStream<BluetoothDevice, Error> {
        logger.log(.debug, "scan(configuration:) called")
        return transport.scan(configuration: configuration)
    }

    public func stopScanning() async {
        await transport.stopScan()
    }

    public func connect(to device: BluetoothDevice) async throws {
        logger.log(.debug, "connect(to:) called for \(device.id)")
        try await transport.connect(to: device)
    }

    /// Connects with bounded retries. Retries only connection failures, not authorization or power errors.
    /// A single connection attempt times out in the CoreBluetooth adapter.
    public func connect(to device: BluetoothDevice, policy: ReconnectPolicy) async throws {
        let attempts: Int
        switch policy {
        case .disabled: attempts = 1
        case .immediate(let maxAttempts), .exponentialBackoff(let maxAttempts, _):
            attempts = max(1, maxAttempts + 1)
        }
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                try await connect(to: device)
                return
            } catch {
                let retryable = [BluetoothError.connectionFailed, .timeout, .disconnected]
                    .contains(error as? BluetoothError ?? .unsupported)
                guard attempt + 1 < attempts, !Task.isCancelled, retryable else { throw error }
                let delay: TimeInterval
                switch policy {
                case .disabled: delay = 0
                case .immediate: delay = 0
                case .exponentialBackoff(_, let initialDelay):
                    delay = min(60, max(0, initialDelay) * pow(2, Double(attempt)))
                }
                logger.log(.debug, "Connection retry \(attempt + 1) in \(delay)s")
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    public func discoverServices(on device: BluetoothDevice) async throws -> [GATTService] {
        try await transport.discoverServices(on: device)
    }

    public func discoverCharacteristics(serviceUUID: String, on device: BluetoothDevice) async throws -> [GATTCharacteristic] {
        try await transport.discoverCharacteristics(serviceUUID: serviceUUID, on: device)
    }

    public func read(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) async throws -> Data {
        try await transport.read(characteristicUUID: characteristicUUID, serviceUUID: serviceUUID, on: device)
    }

    public func write(_ data: Data, characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice, type: GATTWriteType = .withResponse) async throws {
        try await transport.write(data, characteristicUUID: characteristicUUID, serviceUUID: serviceUUID, on: device, type: type)
    }

    public func notifications(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) -> AsyncThrowingStream<Data, Error> {
        transport.notifications(characteristicUUID: characteristicUUID, serviceUUID: serviceUUID, on: device)
    }

    public func disconnect(from device: BluetoothDevice) async {
        logger.log(.debug, "disconnect(from:) called for \(device.id)")
        await transport.disconnect(from: device)
    }
}

private struct UnsupportedBluetoothTransport: BluetoothTransport {
    var state: BluetoothState { get async { .unsupported } }

    func scan(configuration: ScanConfiguration) -> AsyncThrowingStream<BluetoothDevice, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BluetoothError.unsupported)
        }
    }

    func connectionEvents() -> AsyncStream<ConnectionEvent> { AsyncStream { $0.finish() } }
    func stateEvents() -> AsyncStream<BluetoothState> { AsyncStream { $0.yield(.unsupported); $0.finish() } }
    func setAutoReconnect(_ policy: ReconnectPolicy, for device: BluetoothDevice) async {}
    func disableAutoReconnect(for device: BluetoothDevice) async {}
    func stopScan() async {}
    func connect(to device: BluetoothDevice) async throws { throw BluetoothError.unsupported }
    func disconnect(from device: BluetoothDevice) async {}
    func discoverServices(on device: BluetoothDevice) async throws -> [GATTService] { throw BluetoothError.unsupported }
    func discoverCharacteristics(serviceUUID: String, on device: BluetoothDevice) async throws -> [GATTCharacteristic] { throw BluetoothError.unsupported }
    func read(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) async throws -> Data { throw BluetoothError.unsupported }
    func write(_ data: Data, characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice, type: GATTWriteType) async throws { throw BluetoothError.unsupported }
    func notifications(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish(throwing: BluetoothError.unsupported) }
    }
}
