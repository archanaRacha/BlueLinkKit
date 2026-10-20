import Foundation

/// Bluetooth UUIDs are strings because standard GATT UUIDs can be 16/32 bits.
public struct GATTService: Sendable, Hashable, Identifiable {
    public let uuid: String
    public let isPrimary: Bool
    public var id: String { uuid }
    public init(uuid: String, isPrimary: Bool) { self.uuid = uuid.uppercased(); self.isPrimary = isPrimary }
}

public struct GATTCharacteristic: Sendable, Hashable, Identifiable {
    public let uuid: String
    public let serviceUUID: String
    public let properties: CharacteristicProperties
    public var id: String { serviceUUID + ":" + uuid }
    public init(uuid: String, serviceUUID: String, properties: CharacteristicProperties) {
        self.uuid = uuid.uppercased(); self.serviceUUID = serviceUUID.uppercased(); self.properties = properties
    }
}

public enum GATTWriteType: Sendable { case withResponse, withoutResponse }
