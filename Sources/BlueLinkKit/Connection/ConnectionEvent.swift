import Foundation

/// Events emitted by the underlying BLE transport. Each observer receives future events.
public struct ConnectionEvent: Sendable, Equatable {
    public let deviceID: UUID
    public let state: ConnectionState

    public init(deviceID: UUID, state: ConnectionState) {
        self.deviceID = deviceID
        self.state = state
    }
}
