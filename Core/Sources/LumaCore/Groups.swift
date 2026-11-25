import Foundation

/// A named look saved inside a group. Each light can have its own look (`lightStates`);
/// lights the preset doesn't mention (e.g. added to the group later) get `state`.
public struct LightPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var state: LightState
    public var lightStates: [UUID: LightState]

    public init(id: UUID = UUID(), name: String, state: LightState, lightStates: [UUID: LightState] = [:]) {
        self.id = id
        self.name = name
        self.state = state
        self.lightStates = lightStates
    }

    /// Captures the current look of each light; `state` becomes the first light's look.
    public init(id: UUID = UUID(), name: String, capturing looks: [(UUID, LightState)]) {
        self.init(id: id, name: name, state: looks.first?.1 ?? LightState(),
                  lightStates: Dictionary(looks, uniquingKeysWith: { a, _ in a }))
    }

    public func state(for lightID: UUID) -> LightState {
        lightStates[lightID] ?? state
    }

    /// True when every given light currently shows exactly what this preset would set.
    public func matches(_ current: [(UUID, LightState)]) -> Bool {
        !current.isEmpty && current.allSatisfy { state(for: $0.0) == $0.1 }
    }

    /// The distinct looks this preset gives `memberIDs`, in member order (for previews).
    public func previewStates(memberIDs: [UUID], limit: Int = 4) -> [LightState] {
        var out: [LightState] = []
        for id in memberIDs.isEmpty ? Array(lightStates.keys) : memberIDs {
            let s = state(for: id)
            if !out.contains(s) { out.append(s) }
            if out.count == limit { break }
        }
        return out.isEmpty ? [state] : out
    }

    private enum CodingKeys: String, CodingKey { case id, name, state, lightStates }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        state = try c.decode(LightState.self, forKey: .state)
        // Presets saved before per-light looks existed have no `lightStates`.
        lightStates = try c.decodeIfPresent([UUID: LightState].self, forKey: .lightStates) ?? [:]
    }

    /// Names of the presets earlier versions created automatically. Luma no longer ships
    /// built-in presets; these are only used to find and remove the old ones.
    public static let formerBuiltInNames: Set<String> = ["Relax", "Focus", "Cozy", "Night", "Party"]

    public var isFormerBuiltIn: Bool { Self.formerBuiltInNames.contains(name) }

    /// The former built-ins (kept for tests and reference only; never added to a group).
    static let formerBuiltIns: [LightPreset] = [
        LightPreset(name: "Relax", state: LightState(brightness: 45, mode: .color(RGB(r: 255, g: 140, b: 60)))),
        LightPreset(name: "Focus", state: LightState(brightness: 100, mode: .white(0.1))),
        LightPreset(name: "Cozy", state: LightState(brightness: 60, mode: .white(1))),
        LightPreset(name: "Night", state: LightState(brightness: 8, mode: .color(RGB(r: 255, g: 60, b: 10)))),
        LightPreset(name: "Party", state: LightState(brightness: 100, mode: .color(RGB(r: 170, g: 0, b: 255)))),
    ]
}

/// A set of lights controlled together, with its own presets.
public struct LightGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Ignored when `includesAllLights` is true.
    public var lightIDs: [UUID]
    public var includesAllLights: Bool
    public var presets: [LightPreset]

    public init(id: UUID = UUID(), name: String, lightIDs: [UUID] = [], includesAllLights: Bool = false,
                presets: [LightPreset] = []) {
        self.id = id
        self.name = name
        self.lightIDs = lightIDs
        self.includesAllLights = includesAllLights
        self.presets = presets
    }

    /// Member IDs in the order of `allLightIDs` (so groups list lights in the user's light order).
    public func memberIDs(allLightIDs: [UUID]) -> [UUID] {
        if includesAllLights { return allLightIDs }
        let members = Set(lightIDs)
        return allLightIDs.filter(members.contains)
    }

    public static func allLights(presets: [LightPreset] = []) -> LightGroup {
        LightGroup(name: "All Lights", includesAllLights: true, presets: presets)
    }
}

extension LightPreset {
    /// Converts a legacy global scene, keeping its id, name and state.
    public init(_ scene: LightScene) {
        self.init(id: scene.id, name: scene.name, state: scene.state)
    }
}
