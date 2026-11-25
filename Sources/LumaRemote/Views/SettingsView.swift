import SwiftUI
import LumaCore

struct SettingsView: View {
    @Bindable var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Color Correction", isOn: $manager.colorCorrection)
                } footer: {
                    Text("Adjusts colors so they look like what you picked (DayBetter LEDs over-saturate green and blue). Turn off if whites look pink or colors look wrong.")
                }

                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView(manager: manager) }
                } footer: {
                    Text("Shows every nearby Bluetooth device, each light's services, and the raw bytes sent and received.")
                }

                Section("Tips") {
                    Text("Lights take one connection at a time. If a light won't connect, swipe the DayBetter app away and turn off Bluetooth on other phones nearby.")
                    Text("Lights reconnect automatically whenever they're in range while Luma is open.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
