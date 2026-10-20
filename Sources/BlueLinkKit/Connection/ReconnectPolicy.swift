import Foundation

public enum ReconnectPolicy: Sendable, Equatable {
    case disabled
    case immediate(maxAttempts: Int)
    case exponentialBackoff(maxAttempts: Int, initialDelay: TimeInterval)
}
