import SwiftUI
import LumaCore

/// Create a group (`groupID == nil`) or edit an existing one's name and members.
struct GroupEditorView: View {
    let manager: LightManager
    let groupID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @State private var loaded = false
    @State private var confirmingDelete = false

    private var existing: LightGroup? { groupID.flatMap { manager.group(id: $0) } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Group name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }

                Section {
                    if existing?.includesAllLights == true {
                        Label("Includes every light, including ones you add later", systemImage: "lightbulb.2.fill")
                            .foregroundStyle(.secondary)
                    } else if manager.lights.isEmpty {
                        Text("Add a light first, then pick it here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.lights) { light in
                            memberRow(light)
                        }
                    }
                } header: {
                    Text("Lights")
                } footer: {
                    if existing?.includesAllLights != true, !manager.lights.isEmpty {
                        Text("\(selected.count) selected")
                    }
                }

                if let existing, !existing.includesAllLights {
                    Section {
                        Button("Delete Group", systemImage: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(groupID == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog("Delete \(existing?.name ?? "group")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Group", role: .destructive) {
                    if let groupID { manager.deleteGroup(groupID) }
                    dismiss()
                }
            } message: {
                Text("The lights stay; only the group and its presets are removed.")
            }
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
    }

    private func memberRow(_ light: Light) -> some View {
        Button {
            if selected.contains(light.id) {
                selected.remove(light.id)
            } else {
                selected.insert(light.id)
            }
        } label: {
            HStack(spacing: 12) {
                LightDot(state: light.isReady ? light.state : LightState(isOn: false), size: 22)
                Text(light.name).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected.contains(light.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected.contains(light.id) ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            name = existing.name
            selected = Set(existing.lightIDs)
        }
    }

    private func save() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        // Keep members in the user's light order.
        let members = manager.lights.map(\.id).filter(selected.contains)
        if let existing {
            if existing.name != name { manager.renameGroup(existing.id, to: name) }
            if !existing.includesAllLights { manager.setMembers(of: existing.id, to: members) }
        } else {
            manager.createGroup(named: name, lightIDs: members)
        }
        dismiss()
    }
}
