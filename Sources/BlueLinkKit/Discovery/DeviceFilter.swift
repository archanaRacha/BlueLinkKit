import Foundation

public struct DeviceFilter: Sendable {
    public init() {}

    public func matches(_ device: BluetoothDevice, configuration: ScanConfiguration) -> Bool {
        if let minimumRSSI = configuration.minimumRSSI, device.rssi < minimumRSSI {
            return false
        }

        if let prefix = configuration.namePrefix {
            guard let name = device.name, name.hasPrefix(prefix) else { return false }
        }

        if !configuration.serviceUUIDs.isEmpty {
            let deviceServices = Set(device.advertisedServiceUUIDs)
            guard configuration.serviceUUIDs.contains(where: deviceServices.contains) else {
                return false
            }
        }

        return true
    }
}
