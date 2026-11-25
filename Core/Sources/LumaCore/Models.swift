import Foundation

/// What a light should look like: a color, a white temperature, or an effect.
public struct LightState: Hashable, Codable, Sendable {
    public enum Mode: Hashable, Codable, Sendable {
        case color(RGB)
        /// Warmth 0...1 (0 = coolest, 1 = warmest).
        case white(Double)
        case effect(Effect)
    }

    public var isOn: Bool
    public var brightness: Int
    public var mode: Mode

    public init(isOn: Bool = true, brightness: Int = 100, mode: Mode = .color(.warmWhite)) {
        self.isOn = isOn
        self.brightness = brightness
        self.mode = mode
    }

    /// Frames that bring a strip-protocol light to this state. Prefer `Encoder.frames(for:)`.
    public func frames(colorCorrection: Bool) -> [[UInt8]] {
        Encoder(variant: .strip, colorCorrection: colorCorrection).frames(for: self)
    }
}

/// Legacy global scene, kept only to decode old "scenes.v1" data. Use `LightPreset`.
public struct LightScene: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var state: LightState

    public init(id: UUID = UUID(), name: String, state: LightState) {
        self.id = id
        self.name = name
        self.state = state
    }

    public static let defaults: [LightScene] = [
        LightScene(name: "Relax", state: LightState(brightness: 45, mode: .color(RGB(r: 255, g: 140, b: 60)))),
        LightScene(name: "Focus", state: LightState(brightness: 100, mode: .white(0.1))),
        LightScene(name: "Cozy", state: LightState(brightness: 60, mode: .white(1))),
        LightScene(name: "Night", state: LightState(brightness: 8, mode: .color(RGB(r: 255, g: 60, b: 10)))),
        LightScene(name: "Party", state: LightState(brightness: 100, mode: .color(RGB(r: 170, g: 0, b: 255)))),
    ]
}

/// Coalesces rapid updates (slider drags) so only the latest value per command is sent.
/// Pure state machine; the app drives timing.
public struct Coalescer<Key: Hashable & Sendable>: Sendable {
    private var pending: [Key: [[UInt8]]] = [:]
    private var order: [Key] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// Queues a frame, replacing any unsent frame for the same key but keeping its original position.
    public mutating func enqueue(_ frame: [UInt8], for key: Key) {
        enqueue([frame], for: key)
    }

    /// Queues a group of frames that must be sent together and in order (e.g. mode + color).
    public mutating func enqueue(_ frames: [[UInt8]], for key: Key) {
        if pending[key] == nil { order.append(key) }
        pending[key] = frames
    }

    /// Removes and returns every pending frame in first-queued order.
    public mutating func drain() -> [[UInt8]] {
        defer { pending.removeAll(); order.removeAll() }
        return order.flatMap { pending[$0] ?? [] }
    }
}
