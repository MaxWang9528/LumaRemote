import Testing
@testable import LumaCore

struct ProtocolTests {
    @Test func redColorMatchesPublishedVector() {
        // README of grimsteel/daybetter-led-strip: red = A0 15 06 FF 00 00 25 C0.
        #expect(DayBetter.color(.red, corrected: false) == [0xA0, 0x15, 0x06, 0xFF, 0x00, 0x00, 0x25, 0xC0])
    }

    @Test func crcIsLittleEndianModbus() {
        #expect(DayBetter.crc16Modbus([0xA0, 0x15, 0x06, 0xFF, 0x00, 0x00]) == 0xC025)
        // Standard Modbus check value for "123456789".
        #expect(DayBetter.crc16Modbus(Array("123456789".utf8)) == 0x4B37)
    }

    @Test func modelUUIDs() {
        #expect(DayBetter.modelUUIDs(forService: "E09C") == .init(model: "P09C", service: "E09C", write: "A09C", notify: "F09C"))
        #expect(DayBetter.modelUUIDs(forService: "e031")?.write == "A031")
        #expect(DayBetter.modelUUIDs(forService: "0000E09C-0000-1000-8000-00805F9B34FB")?.notify == "F09C")
        #expect(DayBetter.modelUUIDs(forService: "1811") == nil)
        #expect(DayBetter.modelUUIDs(forService: "E0ZZ") == nil)
    }

    @Test func frameShapes() {
        let on = DayBetter.power(true)
        #expect(Array(on.prefix(4)) == [0xA0, 0x11, 0x04, 0x01])
        #expect(on.count == 6)
        #expect(Array(DayBetter.power(false).prefix(4)) == [0xA0, 0x11, 0x04, 0x00])
        #expect(Array(DayBetter.effect(.fadeSlow).prefix(4)) == [0xA0, 0x12, 0x04, 0x0C])
        #expect(Array(DayBetter.requestStatus().prefix(4)) == [0xA0, 0x10, 0x04, 0x00])
    }

    @Test func brightnessIsClamped() {
        #expect(DayBetter.brightness(150)[3] == 100)
        #expect(DayBetter.brightness(-5)[3] == 0)
        #expect(DayBetter.brightness(42)[3] == 42)
    }

    @Test func colorCorrection() {
        #expect(RGB.white.corrected() == RGB(r: 255, g: 100, b: 140))
        #expect(RGB(r: 0, g: 0, b: 0).corrected() == RGB(r: 0, g: 0, b: 0))
        // Gamma pulls mid values down.
        #expect(RGB(r: 128, g: 0, b: 0).corrected().r < 64)
    }

    @Test func parsesAcksAndStatus() {
        #expect(DayBetter.parse([0xA1, 0x15, 0x04, 0x01, 0x00, 0x00]) == .ack(command: 0x15, accepted: true))
        let off: [UInt8] = [0xA1, 0x10, 0x11, 0x00, 0x01, 0x01, 0x64, 0x32, 0x32, 0xFF, 0x31, 0x2D, 0xF0, 0, 0, 0, 0]
        #expect(DayBetter.parse(off) == .status(isOn: false, brightness: nil))
        var on = off; on[3] = 0x01
        #expect(DayBetter.parse(on) == .status(isOn: true, brightness: nil))
        #expect(DayBetter.parse([0x00, 0x01]) == .unknown([0x00, 0x01]))
    }

    @Test func hexRoundTrip() {
        #expect([UInt8](hexString: "a0 11:04-01") == [0xA0, 0x11, 0x04, 0x01])
        #expect([UInt8](hexString: "A0F") == nil)
        #expect([UInt8](hexString: "ZZ") == nil)
        #expect([UInt8]([0x0A, 0xFF]).hexString == "0A FF")
    }

    @Test func hsvRoundTrip() {
        #expect(RGB(hue: 0, saturation: 1) == .red)
        #expect(RGB(hue: 1.0 / 3, saturation: 1) == RGB(r: 0, g: 255, b: 0))
        let hs = RGB(r: 0, g: 0, b: 255).hueSaturation
        #expect(abs(hs.hue - 2.0 / 3) < 0.001 && hs.saturation == 1)
    }

    @Test func coalescerKeepsLatestPerKey() {
        var c = Coalescer<UInt8>()
        c.enqueue([1], for: 0x13)
        c.enqueue([2], for: 0x15)
        c.enqueue([3], for: 0x13)
        #expect(c.drain() == [[3], [2]])
        #expect(c.isEmpty)
    }

    @Test func stateFrames() {
        #expect(LightState(isOn: false).frames(colorCorrection: true) == [DayBetter.power(false)])
        let s = LightState(brightness: 50, mode: .effect(.strobeRGB))
        #expect(s.frames(colorCorrection: true) == [DayBetter.power(true), DayBetter.effect(.strobeRGB), DayBetter.brightness(50)])
        // CCHIP lights have no effects we know: the effect is skipped, power + brightness still go out.
        #expect(Encoder(variant: .cchip).frames(for: s) == [DayBetter.power(true), DayBetter.brightness(50)])
    }

    @Test func coalescerKeepsGroupsTogether() {
        var c = Coalescer<UInt8>()
        c.enqueue([[1], [2]], for: 0x15)
        c.enqueue([3], for: 0x13)
        c.enqueue([[1], [4]], for: 0x15)
        #expect(c.drain() == [[1], [4], [3]])
    }
}
