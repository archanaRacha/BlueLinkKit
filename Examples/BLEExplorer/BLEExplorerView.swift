import SwiftUI
import BlueLinkKit

@MainActor
final class BLEExplorerModel: ObservableObject {
    @Published var devices: [BluetoothDevice] = []
    @Published var status = "Ready"
    @Published var services: [GATTService] = []
    private let manager = BluetoothManager(logger: ConsoleBluetoothLogger())
    private var scanTask: Task<Void, Never>?

    func startScan() {
        scanTask?.cancel()
        devices = []
        status = "Scanning"
        scanTask = Task {
            do {
                for try await device in manager.scan() {
                    if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i] = device }
                    else { devices.append(device) }
                }
            } catch { status = "Scan error: \(error.localizedDescription)" }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        Task { await manager.stopScanning() }
        status = "Stopped"
    }

    func connect(_ device: BluetoothDevice) {
        status = "Connecting to \(device.name ?? "Device")"
        Task {
            do {
                try await manager.connect(to: device, policy: .exponentialBackoff(maxAttempts: 2, initialDelay: 1))
                services = try await manager.discoverServices(on: device)
                status = "Connected: \(services.count) services"
            } catch { status = "Connection error: \(error.localizedDescription)" }
        }
    }
}

struct BLEExplorerView: View {
    @StateObject private var model = BLEExplorerModel()
    var body: some View {
        NavigationStack {
            List {
                Section("Status") { Text(model.status) }
                Section("Nearby devices") {
                    ForEach(model.devices) { device in
                        Button { model.connect(device) } label: {
                            HStack {
                                Text(device.name ?? "Unnamed")
                                Spacer()
                                Text("\(device.rssi) dBm").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Discovered services") {
                    ForEach(model.services, id: \.uuid) { service in Text(service.uuid) }
                }
            }
            .navigationTitle("BLE Explorer")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Stop") { model.stopScan() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Scan") { model.startScan() } }
            }
        }
    }
}
