@preconcurrency import CoreBluetooth
import Observation
import LumaCore

/// One DayBetter light the user has added. Tracks connection, the last state we set, and (for
/// Diagnostics) the GATT table we discovered.
@MainActor @Observable
final class Light: Identifiable {
    enum Status: Equatable {
        case disconnected
        case connecting
        case discovering
        /// Doing the CCHIP login (newer lights ignore commands until it succeeds).
        case authenticating
        case ready
        /// Connected, but no E0xx/A0xx control characteristic: not the protocol we know.
        case unsupported
    }

    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var status: Status = .disconnected
    var state: LightState
    var gatt: [GATTService] = []

    /// Command set, detected at connect time.
    var variant: DayBetter.Variant = .strip
    @ObservationIgnored var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored var notificationsOn = false
    @ObservationIgnored var loginTimeout: Task<Void, Never>?
    @ObservationIgnored var servicesAwaitingCharacteristics = 0
    @ObservationIgnored var outbox = Coalescer<UInt8>()
    @ObservationIgnored var flushTask: Task<Void, Never>?

    init(peripheral: CBPeripheral, name: String, state: LightState) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        self.name = name
        self.state = state
    }

    var isReady: Bool { status == .ready }

    func encoder(colorCorrection: Bool) -> Encoder {
        Encoder(variant: variant, colorCorrection: colorCorrection)
    }

    var statusText: String {
        switch status {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .discovering: "Setting up…"
        case .authenticating: "Logging in…"
        case .ready: state.isOn ? "On · \(state.brightness)%" : "Off"
        case .unsupported: "Unsupported, see Diagnostics"
        }
    }
}

struct GATTService: Identifiable, Hashable {
    var id: String
    var characteristics: [GATTCharacteristic]
}

struct GATTCharacteristic: Identifiable, Hashable {
    var id: String
    var properties: String
}

/// A peripheral seen while scanning (any device, for Diagnostics and the "Nearby" list).
struct NearbyDevice: Identifiable {
    let id: UUID
    var name: String?
    var rssi: Int
    var services: [String]
    var manufacturerData: String?
    var lastSeen: Date

    var looksCompatible: Bool {
        services.contains { $0.count == 4 && ($0.hasPrefix("C0") || DayBetter.modelUUIDs(forService: $0) != nil) }
            || Self.hasDayBetterModelName(name)
    }

    /// DayBetter model codes look like "P09C", "P052", "P0D0" (P0 + two hex digits).
    static func hasDayBetterModelName(_ name: String?) -> Bool {
        name?.uppercased().contains(/P0[0-9A-F]{2}/) ?? false
    }

    var displayName: String { name ?? "Unnamed device" }
}

struct LogEntry: Identifiable {
    enum Direction: String { case sent = "→", received = "←", info = "•" }
    let id = UUID()
    let date: Date
    let light: String
    let direction: Direction
    let text: String
}

/// What gets persisted for each added light.
struct KnownLight: Codable {
    var id: UUID
    var name: String
    var state: LightState
}
