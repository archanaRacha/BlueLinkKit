# Changelog

## 0.7.0
- Redesigned SwiftUI Explorer with dark dashboard, status cards, searchable devices, RSSI indicators, GATT service names, characteristic inspector, HEX editor and live packet viewer.
- Retains BlueLinkKit v0.6 SDK and BLE APIs unchanged.
- Physical-device UI verification still required.

# Changelog

## 0.6.0
- Added `Examples/BLEExplorerApp.xcodeproj` standalone iOS app with local Swift package reference.
- Added SwiftUI scanner, device list, RSSI, connection status, service/characteristic browser, read, hex write, and live notification packets.
- Retained v0.5 BLE SDK API and behavior.

# Changelog

## 0.5.0
- Added GATT operation timeouts (10 seconds) and cancellation of timeout tasks after callbacks.
- Added Bluetooth state event stream.
- Fail pending GATT/connection requests and stop reconnect tasks on power loss.
- Preserved v0.4 connection lifecycle, auto-reconnect, scanning, and GATT APIs.
