import Foundation

public struct BluetoothDevice: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisedServiceUUIDs: [UUID]
    public let manufacturerData: Data?

    public init(
        id: UUID,
        name: String?,
        rssi: Int,
        advertisedServiceUUIDs: [UUID] = [],
        manufacturerData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
        self.manufacturerData = manufacturerData
    }
}
