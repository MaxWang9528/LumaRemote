@preconcurrency import CoreBluetooth

extension CBManagerState {
    var name: String {
        switch self {
        case .poweredOn: "On"
        case .poweredOff: "Off"
        case .unauthorized: "Not allowed"
        case .unsupported: "Unsupported"
        case .resetting: "Resetting"
        case .unknown: "Starting…"
        @unknown default: "Unknown"
        }
    }
}
