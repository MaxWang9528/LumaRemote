@preconcurrency import CoreBluetooth
import SwiftUI
import LumaCore

struct RootView: View {
    let manager: LightManager

    /// What the shared rename alert is renaming.
    private enum RenameTarget: Equatable {
        case light(UUID)
        case group(UUID)
        case preset(groupID: UUID, presetID: UUID)
        /// Not a rename: naming a new preset saved from the home screen.
        case newPreset(groupID: UUID)

        var title: String {
            switch self {
            case .light: "Rename Light"
            case .group: "Rename Group"
            case .preset: "Rename Preset"
            case .newPreset: "Save Preset"
            }
        }
    }

    /// Which group the editor sheet is showing (`nil` id = a new group).
    private struct EditorTarget: Identifiable {
        let groupID: UUID?
        var id: String { groupID?.uuidString ?? "new" }
    }

    @State private var path: [ControlTarget] = []
    @State private var renaming: RenameTarget?
    @State private var newName = ""
    @State private var editing: EditorTarget?
    @State private var deletingGroup: LightGroup?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let warning = bluetoothWarning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                groupSections

                Section {
                    ForEach(manager.lights) { light in
                        lightRow(light)
                    }
                    .onMove { manager.move(from: $0, to: $1) }
                } header: {
                    Text("My Lights")
                } footer: {
                    if manager.lights.isEmpty {
                        Text("Plug in your DayBetter light and fully close the DayBetter app (swipe it away). A light accepts only one connection at a time.")
                    } else {
                        Text("Swipe a light to rename it.")
                    }
                }

                nearbySection
            }
            .navigationTitle("Luma")
            .navigationDestination(for: ControlTarget.self) { target in
                ControlView(manager: manager, target: target)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if manager.isScanning {
                        Button("Stop", systemImage: "stop.circle") { manager.stopScan() }
                    } else {
                        Button("Scan", systemImage: "plus.magnifyingglass") { manager.startScan() }
                            .disabled(manager.bluetoothState != .poweredOn)
                    }
                }
            }
            .refreshable { manager.startScan() }
            .sheet(isPresented: $showingSettings) {
                SettingsView(manager: manager)
            }
            .sheet(item: $editing) { target in
                GroupEditorView(manager: manager, groupID: target.groupID)
            }
            .alert(renaming?.title ?? "Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete \(deletingGroup?.name ?? "group")?",
                isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
                titleVisibility: .visible,
                presenting: deletingGroup
            ) { group in
                Button("Delete Group", role: .destructive) { manager.deleteGroup(group.id) }
            } message: { _ in
                Text("The lights stay; only the group and its presets are removed.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Renaming

    private func startRenaming(_ target: RenameTarget, current: String) {
        newName = current
        renaming = target
    }

    private func commitRename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let renaming else { return }
        switch renaming {
        case .light(let id):
            if let light = manager.lights.first(where: { $0.id == id }) { manager.rename(light, to: name) }
        case .group(let id):
            manager.renameGroup(id, to: name)
        case .preset(let groupID, let presetID):
            manager.renamePreset(presetID, in: groupID, to: name)
        case .newPreset(let groupID):
            manager.savePreset(named: name, in: groupID)
        }
    }

    // MARK: - Groups

    /// One section per group: the group row, then its presets indented underneath for one-tap use.
    @ViewBuilder
    private var groupSections: some View {
        ForEach(Array(manager.groups.enumerated()), id: \.element.id) { index, group in
            Section {
                groupRow(group, index: index)
                ForEach(group.presets) { preset in
                    presetRow(preset, in: group)
                }
            } header: {
                if index == 0 { Text("Groups") }
            }
        }
        Section {
            Button {
                editing = EditorTarget(groupID: nil)
            } label: {
                Label("New Group", systemImage: "plus.circle.fill")
            }
        } footer: {
            if !manager.groups.isEmpty {
                Text("Tap a preset to apply it. Swipe a group or preset for more options.")
            }
        }
    }

    private func groupRow(_ group: LightGroup, index: Int) -> some View {
        let members = manager.lights(in: group)
        let ready = manager.readyLights(in: group)
        let onCount = ready.filter(\.state.isOn).count
        let looks = ready.reduce(into: [LightState]()) { if !$0.contains($1.state) { $0.append($1.state) } }

        return HStack(spacing: 14) {
            Button {
                path.append(.group(group.id))
            } label: {
                HStack(spacing: 14) {
                    LightCluster(states: looks.isEmpty ? [LightState(isOn: false)] : looks)
                        .frame(width: 38, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.headline).foregroundStyle(.primary)
                        Text(subtitle(members: members.count, ready: ready.count, on: onCount))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(group.name, isOn: Binding(
                get: { onCount > 0 },
                set: { manager.setPower($0, for: manager.readyLights(in: group)) }
            ))
            .labelsHidden()
            .disabled(ready.isEmpty)
        }
        .padding(.vertical, 4)
        .swipeActions {
            if !group.includesAllLights {
                Button("Delete", systemImage: "trash") { deletingGroup = group }
                    .tint(.red)
            }
            Button("Edit", systemImage: "slider.horizontal.3") { editing = EditorTarget(groupID: group.id) }
                .tint(.indigo)
            Button("Rename", systemImage: "pencil") { startRenaming(.group(group.id), current: group.name) }
                .tint(.blue)
        }
        .contextMenu {
            Button("Save Current as Preset", systemImage: "star") {
                startRenaming(.newPreset(groupID: group.id), current: "")
            }
            .disabled(ready.isEmpty)
            Button("Rename", systemImage: "pencil") { startRenaming(.group(group.id), current: group.name) }
            Button("Edit Lights", systemImage: "slider.horizontal.3") { editing = EditorTarget(groupID: group.id) }
            if index > 0 {
                Button("Move Up", systemImage: "arrow.up") { manager.moveGroups(from: [index], to: index - 1) }
            }
            if index < manager.groups.count - 1 {
                Button("Move Down", systemImage: "arrow.down") { manager.moveGroups(from: [index], to: index + 2) }
            }
            if !group.includesAllLights {
                Button("Delete Group", systemImage: "trash", role: .destructive) { deletingGroup = group }
            }
        }
    }

    /// An indented, one-tap preset row under its group.
    private func presetRow(_ preset: LightPreset, in group: LightGroup) -> some View {
        let ready = manager.readyLights(in: group)
        let active = manager.isActive(preset, in: group)
        return Button {
            manager.applyPreset(preset, in: group.id)
        } label: {
            HStack(spacing: 12) {
                LightCluster(states: preset.previewStates(memberIDs: manager.lights(in: group).map(\.id)), size: 22)
                    .frame(width: 30, alignment: .leading)
                Text(preset.name)
                    .foregroundStyle(ready.isEmpty ? .secondary : .primary)
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 30) // indent under the group
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ready.isEmpty)
        .accessibilityLabel("Apply \(preset.name) to \(group.name)")
        .accessibilityAddTraits(active ? .isSelected : [])
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                manager.deletePreset(preset.id, in: group.id)
            }
            Button("Update", systemImage: "arrow.triangle.2.circlepath") {
                manager.updatePreset(preset.id, in: group.id)
            }
            .tint(.orange)
            Button("Rename", systemImage: "pencil") {
                startRenaming(.preset(groupID: group.id, presetID: preset.id), current: preset.name)
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                startRenaming(.preset(groupID: group.id, presetID: preset.id), current: preset.name)
            }
            Button("Update to Current", systemImage: "arrow.triangle.2.circlepath") {
                manager.updatePreset(preset.id, in: group.id)
            }
            .disabled(ready.isEmpty)
            Button("Delete", systemImage: "trash", role: .destructive) {
                manager.deletePreset(preset.id, in: group.id)
            }
        }
    }

    private func subtitle(members: Int, ready: Int, on: Int) -> String {
        if members == 0 { return "No lights" }
        let count = members == 1 ? "1 light" : "\(members) lights"
        if ready == 0 { return "\(count) · Not connected" }
        return "\(count) · \(on) on"
    }

    // MARK: - Lights

    private func lightRow(_ light: Light) -> some View {
        NavigationLink(value: ControlTarget.light(light.id)) {
            HStack(spacing: 14) {
                LightDot(state: light.isReady ? light.state : LightState(isOn: false))
                VStack(alignment: .leading, spacing: 2) {
                    Text(light.name).font(.headline)
                    Text(light.statusText).font(.caption)
                        .foregroundStyle(light.status == .unsupported ? .orange : .secondary)
                }
                Spacer()
                if light.isReady {
                    Toggle(light.name, isOn: Binding(
                        get: { light.state.isOn },
                        set: { manager.setPower($0, for: [light]) }
                    ))
                    .labelsHidden()
                } else if light.status != .unsupported {
                    ProgressView()
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button("Rename", systemImage: "pencil") { startRenaming(.light(light.id), current: light.name) }
                .tint(.blue)
        }
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) { manager.remove(light) }
            Button("Rename", systemImage: "pencil") { startRenaming(.light(light.id), current: light.name) }
                .tint(.blue)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRenaming(.light(light.id), current: light.name) }
            Button("Reconnect", systemImage: "arrow.clockwise") { manager.reconnect(light) }
            Button("Remove", systemImage: "trash", role: .destructive) { manager.remove(light) }
        }
    }

    // MARK: - Nearby

    @ViewBuilder
    private var nearbySection: some View {
        let devices = manager.newCompatibleDevices
        if manager.isScanning || !devices.isEmpty {
            Section {
                ForEach(devices) { device in
                    HStack {
                        Image(systemName: "lightbulb").frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(device.displayName)
                            Text("Signal \(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") { manager.add(device) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                HStack {
                    Text("Nearby")
                    if manager.isScanning { ProgressView().controlSize(.small) }
                }
            } footer: {
                if manager.isScanning && devices.isEmpty {
                    Text("Looking for DayBetter lights… If yours never shows up, open Settings → Diagnostics to see every nearby device.")
                }
            }
        }
    }

    private var bluetoothWarning: String? {
        switch manager.bluetoothState {
        case .poweredOff: "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized: "Luma doesn't have Bluetooth permission. Enable it in Settings → Luma."
        case .unsupported: "This device doesn't support Bluetooth LE."
        default: nil
        }
    }
}
