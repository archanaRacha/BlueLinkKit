import XCTest
@testable import BlueLinkKit

final class BlueLinkKitTests: XCTestCase {
    func testDeviceFilterByRSSI() {
        let device = BluetoothDevice(id: UUID(), name: "Sensor", rssi: -70)
        let config = ScanConfiguration(minimumRSSI: -60)
        XCTAssertFalse(DeviceFilter().matches(device, configuration: config))
    }

    func testDeviceFilterByNamePrefix() {
        let device = BluetoothDevice(id: UUID(), name: "Ring-123", rssi: -40)
        let config = ScanConfiguration(namePrefix: "Ring")
        XCTAssertTrue(DeviceFilter().matches(device, configuration: config))
    }

    func testDefaultScanConfiguration() {
        XCTAssertEqual(ScanConfiguration.default, ScanConfiguration())
    }
}
