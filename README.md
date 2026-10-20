# BlueLinkKit 0.7.0

Swift package + polished SwiftUI BLE Explorer demo (iOS 16+).

## Open the demo
Open `Examples/BLEExplorerApp.xcodeproj` in Xcode, select the BLEExplorerApp scheme, configure signing, and run on a physical iPhone. Grant Bluetooth permission.

## Explorer UI
Dark dashboard, nearby device search, scan/stop, signal strength, connection state, service and characteristic browsing, read/notify/write, HEX payload inspector and live packet list.

## Important
This release updates the demo UI, not the underlying BLE SDK. Test on real BLE hardware; Xcode/iOS compilation has not been performed in this Linux environment.



## 📱 BlueLinkKit Explorer

A SwiftUI demo application showcasing BlueLinkKit running on a physical iPhone.

### Screenshots

| Device Scanning | Device Connected | GATT Services |
|:---:|:---:|:---:|
| <img src="docs/screenshots/device-scanning.png" width="220" alt="BLE device scanning"> | <img src="docs/screenshots/device-connected.png" width="220" alt="BLE device connected"> | <img src="docs/screenshots/gatt-services.png" width="220" alt="GATT service discovery"> |

### 🎥 Watch the Demo

[![Watch BlueLinkKit Demo](docs/screenshots/device-connected.png)](docs/demo/bluelinkkit-demo.mp4)

**[▶ Watch the full BLE Explorer demo](docs/demo/bluelinkkit-demo.mp4)**

The demo demonstrates BLE scanning, connecting to a real peripheral, and discovering GATT services.

### Technologies

Swift · SwiftUI · CoreBluetooth · Swift Concurrency · Swift Package Manager

  
