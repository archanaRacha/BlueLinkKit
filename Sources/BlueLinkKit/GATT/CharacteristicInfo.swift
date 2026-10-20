import Foundation

public struct CharacteristicInfo: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let serviceID: UUID
    public let properties: CharacteristicProperties

    public init(id: UUID, serviceID: UUID, properties: CharacteristicProperties) {
        self.id = id
        self.serviceID = serviceID
        self.properties = properties
    }
}

public struct CharacteristicProperties: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let read = CharacteristicProperties(rawValue: 1 << 0)
    public static let write = CharacteristicProperties(rawValue: 1 << 1)
    public static let writeWithoutResponse = CharacteristicProperties(rawValue: 1 << 2)
    public static let notify = CharacteristicProperties(rawValue: 1 << 3)
    public static let indicate = CharacteristicProperties(rawValue: 1 << 4)
}
