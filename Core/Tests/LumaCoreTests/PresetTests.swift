import Foundation
import Testing
@testable import LumaCore

struct PresetTests {
    let a = UUID(), b = UUID(), c = UUID()
    let red = LightState(mode: .color(RGB(r: 255, g: 0, b: 0)))
    let blue = LightState(brightness: 40, mode: .color(RGB(r: 0, g: 0, b: 255)))

    @Test func perLightLooks() {
        let p = LightPreset(name: "Split", capturing: [(a, red), (b, blue)])
        #expect(p.state(for: a) == red)
        #expect(p.state(for: b) == blue)
        #expect(p.state(for: c) == red) // unknown light falls back to the first look
        #expect(p.matches([(a, red), (b, blue)]))
        #expect(!p.matches([(a, blue), (b, blue)]))
        #expect(!p.matches([]))
        #expect(p.previewStates(memberIDs: [a, b, c]) == [red, blue])
    }

    @Test func decodesPresetsSavedBeforePerLightLooks() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Warm","state":{"isOn":true,"brightness":50,"mode":{"white":{"_0":0.8}}}}"#
        let p = try JSONDecoder().decode(LightPreset.self, from: Data(old.utf8))
        #expect(p.lightStates.isEmpty)
        #expect(p.state(for: a) == p.state)
    }

    @Test func roundTripKeepsPerLightLooks() throws {
        let p = LightPreset(name: "Split", capturing: [(a, red), (b, blue)])
        let back = try JSONDecoder().decode(LightPreset.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
}
