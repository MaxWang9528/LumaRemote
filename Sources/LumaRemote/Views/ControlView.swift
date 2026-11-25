import SwiftUI
import LumaCore

/// What a control screen drives: one light or a group.
enum ControlTarget: Hashable {
    case light(UUID)
    case group(UUID)
}

/// Controls one light or a group of lights.
struct ControlView: View {
    let manager: LightManager
    let target: ControlTarget

    init(manager: LightManager, target: ControlTarget) {
        self.manager = manager
        self.target = target
    }

    @State private var tab = Tab.color
    @AppStorage("colorSubtab") private var colorSubtab = ColorSubtab.wheel

    @State private var renaming = false
    @State private var newName = ""
    @State private var editingGroup = false

    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var renamingPreset: LightPreset?
    @State private var renamingPresetShown = false
    @State private var presetRename = ""

    enum Tab: String, CaseIterable { case color = "Color", white = "White", effects = "Effects" }
    enum ColorSubtab: String, CaseIterable { case wheel = "Wheel", grid = "Grid" }

    private static let whitePresets: [(String, Double)] = [
        ("Candle", 1), ("Warm", 0.75), ("Neutral", 0.5), ("Daylight", 0.25), ("Cool", 0),
    ]

    // MARK: - Target resolution (on every render, so lights that connect while open are included)

    private var groupID: UUID? {
        if case .group(let id) = target { id } else { nil }
    }

    private var group: LightGroup? {
        groupID.flatMap { manager.group(id: $0) }
    }

    private var targetLight: Light? {
        if case .light(let id) = target { manager.light(for: id) } else { nil }
    }

    /// Nil when the light or group no longer exists.
    private var title: String? {
        switch target {
        case .light: targetLight?.name
        case .group: group?.name
        }
    }

    private var lights: [Light] {
        switch target {
        case .light:
            if let light = targetLight, light.isReady { [light] } else { [] }
        case .group:
            if let group { manager.readyLights(in: group) } else { [] }
        }
    }

    // MARK: - Body

    var body: some View {
        if let title {
            content(title: title, lights: lights)
        } else {
            ContentUnavailableView(
                groupID == nil ? "Light Removed" : "Group Deleted",
                systemImage: groupID == nil ? "lightbulb.slash" : "square.stack.3d.up.slash",
                description: Text(groupID == nil ? "This light is no longer in your list." : "This group no longer exists.")
            )
        }
    }

    @ViewBuilder
    private func content(title: String, lights: [Light]) -> some View {
        // The first light stands in for the group's state.
        let state = lights.first?.state ?? LightState(isOn: false)
        let tint = state.isOn ? state.displayColor : .gray
        // Effects are only known for strip-protocol lights.
        let tabs = Tab.allCases.filter { $0 != .effects || lights.contains { $0.variant == .strip } }
        let shownTab = tabs.contains(tab) ? tab : .color

        ScrollView {
            VStack(spacing: 24) {
                if lights.isEmpty {
                    ContentUnavailableView("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text(groupID == nil
                                               ? "Make sure the light is powered and the DayBetter app is fully closed."
                                               : "No light in this group is connected. Make sure they are powered and the DayBetter app is fully closed."))
                }

                header(state: state, tint: tint, lights: lights)

                BrightnessSlider(value: state.brightness, tint: tint) {
                    manager.setBrightness($0, for: lights)
                }
                .disabled(lights.isEmpty)

                if let group {
                    presetsRow(group: group, state: state, lights: lights)
                    membersList(group: group)
                }

                Picker("Mode", selection: $tab) {
                    ForEach(tabs, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)

                Group {
                    switch shownTab {
                    case .color: colorPane(state: state, lights: lights)
                    case .white: whitePane(state: state, lights: lights)
                    case .effects: effectsPane(state: state, lights: lights)
                    }
                }
                .disabled(lights.isEmpty)
            }
            .padding()
        }
        .background(alignment: .top) { ambientGlow(tint: tint, isOn: state.isOn && !lights.isEmpty) }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = title
                        renaming = true
                    }
                    if groupID != nil {
                        Button("Edit Group", systemImage: "square.stack.3d.up") { editingGroup = true }
                        Button("Save Preset", systemImage: "star") { startSavingPreset() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert(groupID == nil ? "Rename Light" : "Rename Group", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                guard let groupID, let group else { return }
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                manager.savePreset(named: name.isEmpty ? "Preset \(group.presets.count + 1)" : name, in: groupID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves how each light in this group looks right now, including lights you've set to different colors.")
        }
        .alert("Rename Preset", isPresented: $renamingPresetShown, presenting: renamingPreset) { preset in
            TextField("Name", text: $presetRename)
            Button("Save") {
                let name = presetRename.trimmingCharacters(in: .whitespacesAndNewlines)
                if let groupID, !name.isEmpty { manager.renamePreset(preset.id, in: groupID, to: name) }
                renamingPreset = nil
            }
            Button("Cancel", role: .cancel) { renamingPreset = nil }
        }
        .sheet(isPresented: $editingGroup) {
            if let groupID { GroupEditorView(manager: manager, groupID: groupID) }
        }
        .onAppear {
            if state.isEffect, tabs.contains(.effects) { tab = .effects }
            if case .white = state.mode { tab = .white }
        }
    }

    private func commitRename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch target {
        case .light:
            if let light = targetLight { manager.rename(light, to: name) }
        case .group(let id):
            manager.renameGroup(id, to: name)
        }
    }

    // MARK: - Header

    private func header(state: LightState, tint: Color, lights: [Light]) -> some View {
        HStack(spacing: 20) {
            Group {
                let looks = lights.reduce(into: [LightState]()) { if !$0.contains($1.state) { $0.append($1.state) } }
                if looks.count > 1 {
                    LightCluster(states: looks, size: 64)
                } else {
                    LightDot(state: state, size: 64)
                        .glow(tint, radius: 28, isActive: state.isOn && !lights.isEmpty)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(state.isOn ? state.summary : "Off").font(.title2.bold())
                if groupID != nil {
                    Text(lights.count == 1 ? "1 light" : "\(lights.count) lights").foregroundStyle(.secondary)
                }
            }
            Spacer()
            PowerButton(isOn: state.isOn, tint: tint) {
                manager.setPower(!state.isOn, for: lights)
            }
            .disabled(lights.isEmpty)
        }
    }

    /// A soft wash of the current light color behind the top of the screen.
    private func ambientGlow(tint: Color, isOn: Bool) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 360, height: 360)
            .blur(radius: 90)
            .opacity(isOn ? 0.35 : 0)
            .offset(y: -140)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.4), value: isOn)
    }

    // MARK: - Presets

    private func presetsRow(group: LightGroup, state: LightState, lights: [Light]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Presets").font(.headline)
                Spacer()
                Button {
                    startSavingPreset()
                } label: {
                    Label("Save Preset", systemImage: "star.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(lights.isEmpty)
            }
            if group.presets.isEmpty {
                Text("Set the lights how you like, then tap Save Preset to keep that look for this group.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.presets, id: \.id) { preset in
                        PresetChip(preset: preset, isActive: manager.isActive(preset, in: group),
                                   memberIDs: lights.map(\.id)) {
                            manager.applyPreset(preset, in: group.id)
                        }
                        .disabled(lights.isEmpty)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                presetRename = preset.name
                                renamingPreset = preset
                                renamingPresetShown = true
                            }
                            Button("Update to Current", systemImage: "arrow.triangle.2.circlepath") {
                                manager.updatePreset(preset.id, in: group.id)
                            }
                            .disabled(lights.isEmpty)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                manager.deletePreset(preset.id, in: group.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 12) // room for chip glow
                .padding(.horizontal, 4)
            }
            .padding(.vertical, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every light in the group, each opening its own controls, so one preset can mix colors.
    private func membersList(group: LightGroup) -> some View {
        let members = manager.lights(in: group)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Lights").font(.headline)
            if members.count > 1 {
                Text("Tap a light to give it its own color, then save a preset to keep the mix.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, light in
                    if index > 0 { Divider().padding(.leading, 56) }
                    HStack(spacing: 14) {
                        NavigationLink(value: ControlTarget.light(light.id)) {
                            HStack(spacing: 14) {
                                LightDot(state: light.isReady ? light.state : LightState(isOn: false), size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(light.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(light.isReady ? light.state.summary : light.statusText)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle(light.name, isOn: Binding(
                            get: { light.state.isOn },
                            set: { manager.setPower($0, for: [light]) }
                        ))
                        .labelsHidden()
                        .disabled(!light.isReady)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.11)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startSavingPreset() {
        presetName = ""
        savingPreset = true
    }

    // MARK: - Panes

    @ViewBuilder
    private func colorPane(state: LightState, lights: [Light]) -> some View {
        let current: RGB? = if case .color(let c) = state.mode { c } else { nil }

        Picker("Color picker", selection: $colorSubtab) {
            ForEach(ColorSubtab.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, 48)

        switch colorSubtab {
        case .wheel:
            ColorWheel(color: current) { manager.setColor($0, for: lights) }
                .glow(current?.color ?? .clear, radius: 24, isActive: state.isOn && current != nil)
        case .grid:
            ColorGrid(selected: current) { manager.setColor($0, for: lights) }
        }
    }

    @ViewBuilder
    private func whitePane(state: LightState, lights: [Light]) -> some View {
        let warmth: Double? = if case .white(let w) = state.mode { w } else { nil }

        WarmthSlider(warmth: warmth ?? 0.75) { manager.setWhite(warmth: $0, for: lights) }

        HStack(spacing: 10) {
            ForEach(Self.whitePresets, id: \.0) { name, w in
                let color = Encoder.approximateWhite(warmth: w).color
                let selected = warmth.map { abs($0 - w) < 0.02 } == true
                Button {
                    manager.setWhite(warmth: w, for: lights)
                } label: {
                    VStack(spacing: 6) {
                        Circle().fill(color).frame(width: 36, height: 36)
                            .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 3 : 0))
                            .glow(color, radius: selected ? 14 : 6)
                        Text(name).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name) white")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func effectsPane(state: LightState, lights: [Light]) -> some View {
        let active: Effect? = if case .effect(let e) = state.mode { e } else { nil }

        ForEach(Effect.Group.allCases, id: \.self) { category in
            VStack(alignment: .leading, spacing: 10) {
                Text(category.rawValue).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(Effect.allCases.filter { $0.group == category }) { effect in
                        let effectState = LightState(mode: .effect(effect))
                        let isActive = active == effect
                        Button {
                            manager.setEffect(effect, for: lights)
                        } label: {
                            HStack(spacing: 8) {
                                LightDot(state: effectState, size: 14)
                                Text(effect.name).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? effectState.displayColor.opacity(0.35) : Color(white: 0.15))
                            )
                            .glow(effectState.displayColor, radius: 10, isActive: isActive && state.isOn)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(effect.name)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
