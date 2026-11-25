import Testing
@testable import LumaCore

/// Every vector here is a frame captured from the DayBetter iOS app talking to a P09C bulb
/// (bletrace capture of 2026-11-24).
struct CchipTests {
    private func hex(_ s: String) -> [UInt8] { [UInt8](hexString: s)! }

    @Test func loginFrames() {
        #expect(DayBetter.Login.hello() == hex("A0 00 08 43 43 48 49 50 AC CA"))
        #expect(DayBetter.Login.answer(challenge: [0x06, 0x03]) == hex("A0 01 0A 43 43 48 49 50 22 4F 28 4A"))
        #expect(DayBetter.Login.answer(challenge: [0x00, 0x07]) == hex("A0 01 0A 43 43 48 49 50 24 4B 2A 29"))
        #expect(DayBetter.Login.answer(challenge: [0x02, 0x00]) == hex("A0 01 0A 43 43 48 49 50 26 4C 6A 8B"))
    }

    @Test func parsesLoginReplies() {
        #expect(DayBetter.parse(hex("A1 00 0A 43 43 48 49 50 06 03 6E EA")) == .challenge([0x06, 0x03]))
        #expect(DayBetter.parse(hex("A1 01 09 43 43 48 49 50 00 16 E1")) == .login(accepted: true))
        #expect(DayBetter.parse(hex("A1 01 09 43 43 48 49 50 01 D7 21")) == .login(accepted: false))
    }

    @Test func parsesLongStatus() {
        let s = hex("A1 10 2D 01 00 41 64 4F 28 FE 01 00 00 00 01 02 00 D4 B5 1F 42 14 50 D2 C2 00 00 01 01 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 01 3D F4")
        #expect(DayBetter.parse(s) == .status(isOn: true, brightness: 100))
        #expect(DayBetter.parse(hex("A1 11 04 01 B0 DD")) == .ack(command: 0x11, accepted: true))
    }

    @Test func commandFrames() {
        let e = Encoder(variant: .cchip)
        #expect(e.status() == hex("A0 10 04 01 E0 E1"))
        #expect(e.power(false) == [hex("A0 11 04 00 70 E1")])
        #expect(e.power(true) == [hex("A0 11 04 01 B1 21")])
        #expect(e.brightness(25) == [hex("A0 13 04 19 10 EB")])
        #expect(e.color(RGB(r: 0xFE, g: 0x01, b: 0)) == [hex("A0 12 04 01 41 21"), hex("A0 15 07 FE 01 00 00 6C 27")])
        #expect(e.color(RGB(r: 0, g: 0, b: 255))[1] == hex("A0 15 07 00 00 FF 00 4D FF"))
        #expect(e.effect(.fadeQuick) == nil)
    }

    @Test func whiteFrames() {
        let e = Encoder(variant: .cchip)
        // Captured: A0 12 04 00 80 E1, then A0 20 07 FF FF 00 FF 49 CE.
        let cool = Encoder.warmByteIsFirst ? 0.0 : 1.0
        #expect(e.white(warmth: cool) == [hex("A0 12 04 00 80 E1"), hex("A0 20 07 FF FF 00 FF 49 CE")])
        let frames = e.white(warmth: 0.5)
        #expect(frames[1][3] == 0xFF && frames[1][4] == 0xFF && Int(frames[1][5]) + Int(frames[1][6]) == 255)
    }

    @Test func stripStatusRequestUnchanged() {
        #expect(Encoder(variant: .strip).status() == hex("A0 10 04 00 21 21"))
    }
}
