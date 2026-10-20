import Foundation

public struct ServiceInfo: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let isPrimary: Bool

    public init(id: UUID, isPrimary: Bool) {
        self.id = id
        self.isPrimary = isPrimary
    }
}
