import SwiftUI
import LumaCore

/// For when a light doesn't behave: what's nearby, what each light exposes, and the raw traffic.
struct DiagnosticsView: View {
    let manager: LightManager

    var body: some View {
        List {
            Section("Bluetooth") {
                LabeledContent("State", value: String(describing: manager.bluetoothState.name))
                Button(manager.isScanning ? "Scanning…" : "Scan for 15 s") { manager.startScan() }
                    .disabled(manager.isScanning)
            }

            if !manager.lights.isEmpty {
                Section("My Lights") {
                    ForEach(manager.lights) { light in
                        NavigationLink {
                            LightDiagnosticsView(manager: manager, light: light)
                        } label: {
                            LabeledContent(light.name, value: light.statusText)
                        }
                    }
                }
            }

            Section {
                let devices = manager.nearby.values.sorted { $0.rssi > $1.rssi }
                if devices.isEmpty {
                    Text("Nothing yet. Tap Scan.").foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(device.displayName).font(.headline)
                            if device.looksCompatible {
                                Text("DayBetter").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(.green.opacity(0.3)))
                            }
                            Spacer()
                            Text("\(device.rssi) dBm").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(device.services.isEmpty ? "No advertised services" : "Services: " + device.services.joined(separator: ", "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(device.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        if manager.light(for: device.id) == nil {
                            Button("Add") { manager.add(device) }.tint(.green)
                        }
                    }
                }
            } header: {
                Text("All Nearby Devices")
            } footer: {
                Text("Swipe left on a device to add it as a light anyway. Once connected, its services appear under My Lights.")
            }

            LogSection(manager: manager, filter: nil)
        }
        .navigationTitle("Diagnostics")
    }
}

struct LightDiagnosticsView: View {
    let manager: LightManager
    let light: Light

    @State private var hex = ""

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status", value: light.statusText)
                LabeledContent("ID", value: light.id.uuidString).font(.caption.monospaced())
                Button("Reconnect") { manager.reconnect(light) }
            }

            Section {
                if light.gatt.isEmpty { Text("Not discovered yet").foregroundStyle(.secondary) }
                ForEach(light.gatt) { service in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Service \(service.id)").font(.headline.monospaced())
                        ForEach(service.characteristics) { c in
                            Text("  \(c.id)  [\(c.properties)]").font(.caption.monospaced())
                        }
                    }
                }
            } header: {
                Text("GATT")
            } footer: {
                Text("Luma writes to A0xx and listens on F0xx inside service E0xx, where xx matches the model (P09C → E09C).")
            }

            Section {
                TextField("A0 11 04 01", text: $hex)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                HStack {
                    Button("Send as-is") { send(appendCRC: false) }
                    Spacer()
                    Button("Send + CRC") { send(appendCRC: true) }
                }
                .disabled(!light.isReady || [UInt8](hexString: hex) == nil)
            } header: {
                Text("Send Raw Bytes")
            } footer: {
                Text("\"Send + CRC\" appends the CRC16-Modbus checksum for you.")
            }

            LogSection(manager: manager, filter: light.name)
        }
        .navigationTitle(light.name)
    }

    private func send(appendCRC: Bool) {
        guard var bytes = [UInt8](hexString: hex) else { return }
        if appendCRC {
            let crc = DayBetter.crc16Modbus(bytes)
            bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        }
        manager.sendRaw(bytes, to: light)
    }
}

private struct LogSection: View {
    let manager: LightManager
    let filter: String?

    var body: some View {
        Section {
            let entries = manager.log.filter { filter == nil || $0.light == filter }.suffix(100).reversed()
            if entries.isEmpty { Text("No traffic yet").foregroundStyle(.secondary) }
            ForEach(Array(entries)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.date.formatted(date: .omitted, time: .standard)) \(entry.direction.rawValue) \(entry.light)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(entry.text).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                Button("Copy") {
                    UIPasteboard.general.string = manager.log
                        .map { "\($0.date.formatted(date: .omitted, time: .standard)) \($0.direction.rawValue) \($0.light): \($0.text)" }
                        .joined(separator: "\n")
                }
                Button("Clear") { manager.clearLog() }
            }
            .font(.caption)
        }
    }
}
