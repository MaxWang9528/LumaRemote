/// Builds the frames for a user action in the dialect a given light speaks.
///
/// CCHIP lights (P09C bulbs) have two modes, switched with command 0x12:
///   A0 12 04 01  color mode, then  A0 15 07 R G B 00
///   A0 12 04 00  white mode, then  A0 20 07 FF FF a (255-a)
/// The DayBetter app sends the mode frame with every white change and when switching to color,
/// so this encoder always sends it. Two short writes per update are cheap and it can't desync.
/// On strips 0x12 means "effect" instead, so the variants must never be mixed.
public struct Encoder: Sendable {
    public var variant: DayBetter.Variant
    public var colorCorrection: Bool

    /// White byte `a` for a warmth of 1.0. The capture didn't say which end is warm, so this is
    /// the one constant to flip if the slider turns out backwards on real bulbs.
    public static let warmByteIsFirst = true

    public init(variant: DayBetter.Variant, colorCorrection: Bool = true) {
        self.variant = variant
        self.colorCorrection = colorCorrection
    }

    public var supportsEffects: Bool { variant == .strip }

    public func power(_ on: Bool) -> [[UInt8]] {
        [DayBetter.power(on)]
    }

    public func brightness(_ percent: Int) -> [[UInt8]] {
        [DayBetter.brightness(percent)]
    }

    public func color(_ c: RGB) -> [[UInt8]] {
        switch variant {
        case .strip:
            return [DayBetter.color(c, corrected: colorCorrection)]
        case .cchip:
            return [DayBetter.frame(rawCommand: 0x12, payload: [0x01]),
                    DayBetter.frame(rawCommand: 0x15, payload: [c.r, c.g, c.b, 0x00])]
        }
    }

    /// Warmth 0...1 (0 = coolest, 1 = warmest).
    public func white(warmth: Double) -> [[UInt8]] {
        let w = min(max(warmth, 0), 1)
        switch variant {
        case .strip:
            // Strips have no white channel: approximate with RGB.
            return color(Self.approximateWhite(warmth: w))
        case .cchip:
            let warm = UInt8((w * 255).rounded())
            let pair: [UInt8] = Self.warmByteIsFirst ? [warm, 255 - warm] : [255 - warm, warm]
            return [DayBetter.frame(rawCommand: 0x12, payload: [0x00]),
                    DayBetter.frame(rawCommand: 0x20, payload: [0xFF, 0xFF] + pair)]
        }
    }

    /// nil when the light has no effects we know how to drive.
    public func effect(_ e: Effect) -> [[UInt8]]? {
        supportsEffects ? [DayBetter.effect(e)] : nil
    }

    public func status() -> [UInt8] {
        DayBetter.requestStatus(variant)
    }

    public func frames(for state: LightState) -> [[UInt8]] {
        guard state.isOn else { return power(false) }
        var out = power(true)
        switch state.mode {
        case .color(let c): out += color(c)
        case .white(let w): out += white(warmth: w)
        case .effect(let e): out += effect(e) ?? []
        }
        return out + brightness(state.brightness)
    }

    public static func approximateWhite(warmth w: Double) -> RGB {
        // Lerp between a cool white and a candle-ish warm white.
        let cool = (r: 210.0, g: 225.0, b: 255.0), warm = (r: 255.0, g: 150.0, b: 60.0)
        func mix(_ a: Double, _ b: Double) -> UInt8 { UInt8((a + (b - a) * w).rounded()) }
        return RGB(r: mix(cool.r, warm.r), g: mix(cool.g, warm.g), b: mix(cool.b, warm.b))
    }
}
