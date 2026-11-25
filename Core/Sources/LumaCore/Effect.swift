/// Built-in effects (command 0x12). Codes from the reference library.
public enum Effect: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case showRed = 0x02, showGreen, showBlue, showYellow, showTeal, showPurple, showWhite
    case switchRGB = 0x09
    case switchAllColors = 0x0A
    case fadeQuick = 0x0B
    case fadeSlow = 0x0C
    case blinkRed = 0x0D, blinkGreen, blinkBlue, blinkYellow, blinkTeal, blinkPurple, blinkWhite
    case fadeRedGreen = 0x14
    case fadeRedBlue = 0x15
    case fadeGreenBlue = 0x16
    case flashAllColors = 0x17
    case flashRed = 0x18, flashGreen, flashBlue, flashYellow, flashTeal, flashPurple, flashWhite
    case strobeRGB = 0x1F
    case strobeAllColors = 0x20

    public var id: UInt8 { rawValue }

    public enum Group: String, CaseIterable, Sendable {
        case animated = "Animated"
        case blink = "Blink"
        case flash = "Flash"
    }

    /// The "show a static color" codes duplicate what the color picker does, so the UI hides them.
    public var group: Group? {
        switch self {
        case .showRed, .showGreen, .showBlue, .showYellow, .showTeal, .showPurple, .showWhite: nil
        case .blinkRed, .blinkGreen, .blinkBlue, .blinkYellow, .blinkTeal, .blinkPurple, .blinkWhite: .blink
        case .flashRed, .flashGreen, .flashBlue, .flashYellow, .flashTeal, .flashPurple, .flashWhite: .flash
        default: .animated
        }
    }

    public var name: String {
        switch self {
        case .showRed: "Red"
        case .showGreen: "Green"
        case .showBlue: "Blue"
        case .showYellow: "Yellow"
        case .showTeal: "Teal"
        case .showPurple: "Purple"
        case .showWhite: "White"
        case .switchRGB: "Jump RGB"
        case .switchAllColors: "Jump All"
        case .fadeQuick: "Fade Fast"
        case .fadeSlow: "Fade Slow"
        case .blinkRed: "Red"
        case .blinkGreen: "Green"
        case .blinkBlue: "Blue"
        case .blinkYellow: "Yellow"
        case .blinkTeal: "Teal"
        case .blinkPurple: "Purple"
        case .blinkWhite: "White"
        case .fadeRedGreen: "Red ↔ Green"
        case .fadeRedBlue: "Red ↔ Blue"
        case .fadeGreenBlue: "Green ↔ Blue"
        case .flashAllColors: "Flash All"
        case .flashRed: "Red"
        case .flashGreen: "Green"
        case .flashBlue: "Blue"
        case .flashYellow: "Yellow"
        case .flashTeal: "Teal"
        case .flashPurple: "Purple"
        case .flashWhite: "White"
        case .strobeRGB: "Strobe RGB"
        case .strobeAllColors: "Strobe All"
        }
    }

    /// A representative color for UI swatches; nil means multicolor.
    public var swatch: RGB? {
        switch self {
        case .showRed, .blinkRed, .flashRed: RGB(r: 255, g: 40, b: 40)
        case .showGreen, .blinkGreen, .flashGreen: RGB(r: 40, g: 220, b: 80)
        case .showBlue, .blinkBlue, .flashBlue: RGB(r: 50, g: 100, b: 255)
        case .showYellow, .blinkYellow, .flashYellow: RGB(r: 255, g: 210, b: 40)
        case .showTeal, .blinkTeal, .flashTeal: RGB(r: 40, g: 210, b: 210)
        case .showPurple, .blinkPurple, .flashPurple: RGB(r: 170, g: 70, b: 255)
        case .showWhite, .blinkWhite, .flashWhite: RGB(r: 245, g: 245, b: 245)
        default: nil
        }
    }
}
