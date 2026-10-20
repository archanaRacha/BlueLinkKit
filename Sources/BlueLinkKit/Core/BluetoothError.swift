import Foundation

public enum BluetoothError: Error, Sendable, Equatable {
    case bluetoothUnavailable
    case bluetoothPoweredOff
    case unauthorized
    case unsupported
    case scanningFailed
    case deviceNotFound
    case connectionFailed
    case disconnected
    case serviceNotFound(UUID)
    case characteristicNotFound(UUID)
    case readFailed
    case writeFailed
    case notificationFailed
    case timeout
}
