import Foundation

public enum BluetoothLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol BluetoothLogging: Sendable {
    func log(_ level: BluetoothLogLevel, _ message: @autoclosure @Sendable () -> String)
}

public struct ConsoleBluetoothLogger: BluetoothLogging {
    public init() {}

    public func log(_ level: BluetoothLogLevel, _ message: @autoclosure @Sendable () -> String) {
        #if DEBUG
        print("[BlueLinkKit][\(level.rawValue.uppercased())] \(message())")
        #endif
    }
}

public struct NoopBluetoothLogger: BluetoothLogging {
    public init() {}
    public func log(_ level: BluetoothLogLevel, _ message: @autoclosure @Sendable () -> String) {}
}
