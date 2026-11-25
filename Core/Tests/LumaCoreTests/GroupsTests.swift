import Foundation
import Testing
@testable import LumaCore

struct GroupsTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func memberIDsFollowLightOrder() {
        let group = LightGroup(name: "Desk", lightIDs: [c, a])
        #expect(group.memberIDs(allLightIDs: [a, b, c]) == [a, c])
    }

    @Test func memberIDsDropUnknownLights() {
        let group = LightGroup(name: "Desk", lightIDs: [d, b])
        #expect(group.memberIDs(allLightIDs: [a, b, c]) == [b])
    }

    @Test func allLightsIncludesEveryLight() {
        let group = LightGroup.allLights()
        #expect(group.name == "All Lights")
        #expect(group.includesAllLights)
        #expect(group.memberIDs(allLightIDs: [c, a, b]) == [c, a, b])
        var withStale = group
        withStale.lightIDs = [d]
        #expect(withStale.memberIDs(allLightIDs: [a]) == [a])
    }

    @Test func codableRoundTrip() throws {
        let group = LightGroup(name: "Bedroom", lightIDs: [a, b], presets: [
            LightPreset(name: "Warm", state: LightState(brightness: 30, mode: .white(0.8))),
            LightPreset(name: "Red", state: LightState(isOn: false, brightness: 5, mode: .color(RGB(r: 255, g: 0, b: 0)))),
        ])
        let data = try JSONEncoder().encode([group, .allLights()])
        let decoded = try JSONDecoder().decode([LightGroup].self, from: data)
        #expect(decoded[0] == group)
        #expect(decoded[1].includesAllLights)
        #expect(decoded[1].presets.isEmpty)
    }

    @Test func newGroupsStartWithoutPresets() {
        #expect(LightGroup(name: "X").presets.isEmpty)
        #expect(LightGroup.allLights().presets.isEmpty)
        #expect(LightPreset.formerBuiltIns.allSatisfy { $0.isFormerBuiltIn })
        #expect(LightScene.defaults.allSatisfy { LightPreset($0).isFormerBuiltIn })
        #expect(!LightPreset(name: "Movie night", state: LightState()).isFormerBuiltIn)
    }

    @Test func legacySceneConversionKeepsIdentity() {
        let scene = LightScene.defaults[2]
        let preset = LightPreset(scene)
        #expect(preset.id == scene.id && preset.name == scene.name && preset.state == scene.state)
    }
}
