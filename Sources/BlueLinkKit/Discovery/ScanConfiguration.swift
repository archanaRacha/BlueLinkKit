import Foundation

public struct ScanConfiguration: Sendable, Equatable {
    public var serviceUUIDs: [UUID]
    public var allowDuplicates: Bool
    public var minimumRSSI: Int?
    public var namePrefix: String?

    public init(
        serviceUUIDs: [UUID] = [],
        allowDuplicates: Bool = false,
        minimumRSSI: Int? = nil,
        namePrefix: String? = nil
    ) {
        self.serviceUUIDs = serviceUUIDs
        self.allowDuplicates = allowDuplicates
        self.minimumRSSI = minimumRSSI
        self.namePrefix = namePrefix
    }

    public static let `default` = ScanConfiguration()
}
