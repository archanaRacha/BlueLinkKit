import Foundation

public protocol BluetoothTransport: Sendable {
    var state: BluetoothState { get async }
    func stateEvents() -> AsyncStream<BluetoothState>
    func connectionEvents() -> AsyncStream<ConnectionEvent>
    func setAutoReconnect(_ policy: ReconnectPolicy, for device: BluetoothDevice) async
    func disableAutoReconnect(for device: BluetoothDevice) async
    func scan(configuration: ScanConfiguration) -> AsyncThrowingStream<BluetoothDevice, Error>
    func stopScan() async
    func connect(to device: BluetoothDevice) async throws
    func disconnect(from device: BluetoothDevice) async
    func discoverServices(on device: BluetoothDevice) async throws -> [GATTService]
    func discoverCharacteristics(serviceUUID: String, on device: BluetoothDevice) async throws -> [GATTCharacteristic]
    func read(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) async throws -> Data
    func write(_ data: Data, characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice, type: GATTWriteType) async throws
    func notifications(characteristicUUID: String, serviceUUID: String, on device: BluetoothDevice) -> AsyncThrowingStream<Data, Error>
}
