import SwiftUI
import BlueLinkKit

@MainActor
final class BLEExplorerViewModel: ObservableObject {
    @Published var devices: [BluetoothDevice] = []
    @Published var bluetoothState = "Starting"
    @Published var status = "Ready to scan"
    @Published var selected: BluetoothDevice?
    @Published var services: [GATTService] = []
    @Published var characteristics: [GATTCharacteristic] = []
    @Published var selectedService: GATTService?
    @Published var selectedCharacteristic: GATTCharacteristic?
    @Published var valueHex = ""
    @Published var writeHex = "01"
    @Published var livePackets: [String] = []
    @Published var isScanning = false
    @Published var isConnected = false

    private let manager = BluetoothManager(logger: ConsoleBluetoothLogger())
    private var scanTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?

    init() {
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in manager.stateEvents() {
                self.bluetoothState = String(describing: state)
                if state != .poweredOn { self.isConnected = false }
            }
        }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            for await event in manager.connectionEvents() {
                guard event.deviceID == self.selected?.id else { continue }
                self.status = "Connection: \(event.state)"
                self.isConnected = String(describing: event.state) == "connected"
            }
        }
    }

    func scan() {
        stopScan()
        devices = []
        status = "Scanning nearby devices"
        isScanning = true
        scanTask = Task {
            do {
                for try await device in manager.scan() {
                    guard !Task.isCancelled else { break }
                    if let index = devices.firstIndex(where: { $0.id == device.id }) {
                        devices[index] = device
                    } else { devices.append(device) }
                    devices.sort { $0.rssi > $1.rssi }
                }
            } catch {
                if !Task.isCancelled { status = "Scan failed: \(error.localizedDescription)" }
            }
            isScanning = false
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        Task { await manager.stopScanning() }
    }

    func connect(_ device: BluetoothDevice) {
        stopScan()
        notificationTask?.cancel()
        selected = device
        selectedService = nil
        selectedCharacteristic = nil
        services = []
        characteristics = []
        livePackets = []
        status = "Connecting…"
        Task {
            do {
                await manager.enableAutoReconnect(for: device)
                try await manager.connect(to: device, policy: .exponentialBackoff(maxAttempts: 2, initialDelay: 1))
                isConnected = true
                status = "Connected to \(device.name ?? "Unnamed device")"
                services = try await manager.discoverServices(on: device)
            } catch { status = "Connect failed: \(error.localizedDescription)" }
        }
    }

    func disconnect() {
        guard let device = selected else { return }
        notificationTask?.cancel()
        Task { await manager.disconnect(from: device) }
        isConnected = false
        status = "Disconnected"
    }

    func selectService(_ service: GATTService) {
        guard let device = selected else { return }
        selectedService = service
        selectedCharacteristic = nil
        characteristics = []
        Task {
            do { characteristics = try await manager.discoverCharacteristics(serviceUUID: service.uuid, on: device) }
            catch { status = "Discovery failed: \(error.localizedDescription)" }
        }
    }

    func read(_ characteristic: GATTCharacteristic) {
        guard let device = selected else { return }
        selectedCharacteristic = characteristic
        Task {
            do {
                let data = try await manager.read(characteristicUUID: characteristic.uuid, serviceUUID: characteristic.serviceUUID, on: device)
                valueHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                status = "Read \(data.count) bytes"
            } catch { status = "Read failed: \(error.localizedDescription)" }
        }
    }

    func write() {
        guard let device = selected, let characteristic = selectedCharacteristic else { return }
        let cleaned = writeHex.filter { !$0.isWhitespace && $0 != "," }
        guard cleaned.count.isMultiple(of: 2), !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isHexDigit }) else { status = "Enter valid hex bytes"; return }
        var bytes: [UInt8] = []
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let byte = UInt8(cleaned[i..<j], radix: 16) else { status = "Invalid hex"; return }
            bytes.append(byte)
            i = j
        }
        let type: GATTWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        Task {
            do {
                try await manager.write(Data(bytes), characteristicUUID: characteristic.uuid, serviceUUID: characteristic.serviceUUID, on: device, type: type)
                status = "Wrote \(bytes.count) bytes"
            } catch { status = "Write failed: \(error.localizedDescription)" }
        }
    }

    func subscribe(_ characteristic: GATTCharacteristic) {
        guard let device = selected else { return }
        selectedCharacteristic = characteristic
        notificationTask?.cancel()
        livePackets = []
        notificationTask = Task {
            do {
                for try await data in manager.notifications(characteristicUUID: characteristic.uuid, serviceUUID: characteristic.serviceUUID, on: device) {
                    guard !Task.isCancelled else { break }
                    let line = "\(Date().formatted(date: .omitted, time: .standard))  " + data.map { String(format: "%02X", $0) }.joined(separator: " ")
                    livePackets.insert(line, at: 0)
                    if livePackets.count > 100 { livePackets.removeLast() }
                    valueHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                }
            } catch { if !Task.isCancelled { status = "Notification failed: \(error.localizedDescription)" } }
        }
    }

    func stopNotifications() { notificationTask?.cancel(); notificationTask = nil }
}

private enum ExplorerStyle {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.09)
    static let surface = Color(red: 0.085, green: 0.11, blue: 0.16)
    static let accent = Color(red: 0.25, green: 0.78, blue: 0.92)
}

struct BLEExplorerView: View {
    @StateObject private var model = BLEExplorerViewModel()
    @State private var search = ""
    @State private var showUnnamed = true

    private var visibleDevices: [BluetoothDevice] {
        model.devices.filter { device in
            (showUnnamed || (device.name?.isEmpty == false)) &&
            (search.isEmpty || (device.name ?? "").localizedCaseInsensitiveContains(search) || device.id.uuidString.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            overview
                            devicesPanel
                            if let device = model.selected {
                                selectedPanel(device)
                                servicesPanel
                                if let service = model.selectedService { characteristicsPanel(service) }
                                if let characteristic = model.selectedCharacteristic { inspectorPanel(characteristic) }
                                if !model.livePackets.isEmpty { packetsPanel }
                            }
                            Text("Bluetooth behavior and available GATT operations depend on the connected device.")
                                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
                        }
                        .padding(16)
                    }
                    .background(ExplorerStyle.background.ignoresSafeArea())
                    .navigationTitle("BLE Explorer")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text("v0.7").font(.caption.weight(.bold))
                                .foregroundStyle(ExplorerStyle.accent)
                        }
                    }
                    .preferredColorScheme(.dark)
                    .onDisappear { model.stopScan(); model.stopNotifications() }
                }
            } else {
                // Fallback for iOS versions earlier than 16.0
                NavigationView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            overview
                            devicesPanel
                            if let device = model.selected {
                                selectedPanel(device)
                                servicesPanel
                                if let service = model.selectedService { characteristicsPanel(service) }
                                if let characteristic = model.selectedCharacteristic { inspectorPanel(characteristic) }
                                if !model.livePackets.isEmpty { packetsPanel }
                            }
                            Text("Bluetooth behavior and available GATT operations depend on the connected device.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 24)
                        }
                        .padding(16)
                    }
                    .background(ExplorerStyle.background.ignoresSafeArea())
                    .navigationBarTitle("BLE Explorer", displayMode: .inline)
                }
                .preferredColorScheme(.dark)
                .onDisappear { model.stopScan(); model.stopNotifications() }
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(ExplorerStyle.accent)
                Text("BLUELINKKIT").font(.caption.weight(.bold)).tracking(2)
                Spacer()
                Label(model.bluetoothState, systemImage: "circle.fill")
                    .font(.caption2).foregroundStyle(model.bluetoothState.lowercased().contains("poweredon") ? .green : .orange)
            }
            Text("Bluetooth Device Inspector").font(.title2.bold())
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                stat("Discovered", "\(model.devices.count)", "dot.radiowaves.left.and.right")
                stat("Connection", model.isConnected ? "Online" : "Offline", "link")
            }
        }.panel()
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).foregroundStyle(.white)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var devicesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Nearby Devices").font(.headline)
                Spacer()
                Button { model.isScanning ? model.stopScan() : model.scan() } label: {
                    Label(model.isScanning ? "Stop" : "Scan", systemImage: model.isScanning ? "stop.fill" : "arrow.clockwise")
                }.buttonStyle(.borderedProminent).tint(ExplorerStyle.accent)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Name or identifier", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }.padding(11).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            Toggle("Show unnamed devices", isOn: $showUnnamed).font(.subheadline)
                .tint(ExplorerStyle.accent)
            if visibleDevices.isEmpty {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView(model.isScanning ? "Searching…" : "No devices found", systemImage: "antenna.radiowaves.left.and.right", description: Text("Tap Scan or adjust the filters."))
                        .frame(minHeight: 140)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                        Text(model.isScanning ? "Searching…" : "No devices found")
                            .font(.headline)
                        Text("Tap Scan or adjust the filters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 140)
                }
            } else {
                ForEach(visibleDevices) { device in
                    Button { model.connect(device) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                                .foregroundStyle(ExplorerStyle.accent)
                                .frame(width: 34, height: 34)
                                .background(ExplorerStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name ?? "Unnamed device").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text(device.id.uuidString).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 4) {
                                Image(systemName: signalIcon(device.rssi)).foregroundStyle(signalColor(device.rssi))
                                Text("\(device.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.05))
                }
            }
        }.panel()
    }

    private func selectedPanel(_ device: BluetoothDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Device").font(.headline)
                Spacer()
                Label(model.isConnected ? "Connected" : "Disconnected", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.isConnected ? .green : .orange)
            }
            Text(device.name ?? "Unnamed device").font(.title3.weight(.semibold))
            Text(device.id.uuidString).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Label("\(device.rssi) dBm", systemImage: signalIcon(device.rssi))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { model.disconnect() } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }.buttonStyle(.bordered).disabled(!model.isConnected)
            }
        }.panel()
    }

    private var servicesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GATT Services").font(.headline)
                Spacer()
                Text("\(model.services.count)").font(.caption).foregroundStyle(.secondary)
            }
            if model.services.isEmpty { Text("No services discovered yet").foregroundStyle(.secondary) }
            ForEach(model.services) { service in
                Button { model.selectService(service) } label: {
                    HStack {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(ExplorerStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(serviceName(service.uuid)).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                            Text(service.uuid).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: model.selectedService?.uuid == service.uuid ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundStyle(ExplorerStyle.accent)
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
                Divider().overlay(.white.opacity(0.05))
            }
        }.panel()
    }

    private func characteristicsPanel(_ service: GATTService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Characteristics · \(service.uuid)").font(.headline)
            if model.characteristics.isEmpty { Text("No characteristics found").foregroundStyle(.secondary) }
            ForEach(model.characteristics) { characteristic in
                VStack(alignment: .leading, spacing: 10) {
                    Text(characteristic.uuid).font(.system(.subheadline, design: .monospaced)).bold()
                    HStack(spacing: 8) {
                        if characteristic.properties.contains(.read) { action("Read", "arrow.down.doc") { model.read(characteristic) } }
                        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                            action("Listen", "waveform") { model.subscribe(characteristic) }
                        }
                        if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                            action("Write", "square.and.pencil") { model.selectedCharacteristic = characteristic }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }
        }.panel()
    }

    private func inspectorPanel(_ characteristic: GATTCharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Characteristic Inspector").font(.headline)
            Text(characteristic.uuid).font(.system(.caption, design: .monospaced)).foregroundStyle(ExplorerStyle.accent)
            Text("Latest HEX value").font(.caption).foregroundStyle(.secondary)
            Text(model.valueHex.isEmpty ? "No data yet" : model.valueHex)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                TextField("HEX payload (e.g. 01 FF)", text: $model.writeHex)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                Button("Send HEX") { model.write() }.buttonStyle(.borderedProminent).tint(ExplorerStyle.accent)
            }
            Button("Stop listening") { model.stopNotifications() }.buttonStyle(.bordered)
        }.panel()
    }

    private var packetsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live Packets").font(.headline)
                Spacer()
                Text("\(model.livePackets.count) / 100").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.livePackets.enumerated()), id: \.offset) { _, packet in
                Text(packet).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ExplorerStyle.accent).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(.white.opacity(0.05))
            }
        }.panel()
    }

    private func action(_ title: String, _ icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: icon).font(.caption.weight(.medium)) }
            .buttonStyle(.bordered).tint(ExplorerStyle.accent)
    }

    private func signalIcon(_ rssi: Int) -> String {
        if rssi >= -60 { return "wifi" }
        if rssi >= -80 { return "wifi" }
        return "antenna.radiowaves.left.and.right"
    }
    private func signalColor(_ rssi: Int) -> Color {
        rssi >= -60 ? .green : (rssi >= -80 ? .yellow : .orange)
    }
    private func serviceName(_ uuid: String) -> String {
        switch uuid.uppercased() {
        case "1800": return "Generic Access"
        case "1801": return "Generic Attribute"
        case "1802": return "Immediate Alert"
        case "1803": return "Link Loss"
        case "1804": return "Tx Power"
        case "180A": return "Device Information"
        case "180D": return "Heart Rate"
        case "180F": return "Battery Service"
        case "181A": return "Environmental Sensing"
        case "1822": return "Pulse Oximeter"
        default: return "Service \(uuid)"
        }
    }
}

private struct ExplorerPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(ExplorerStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.07)))
    }
}
private extension View {
    func panel() -> some View { modifier(ExplorerPanel()) }
}
