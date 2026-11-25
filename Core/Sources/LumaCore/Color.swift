import Foundation

public struct RGB: Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Hue, saturation and value in 0...1.
    public init(hue: Double, saturation: Double, value: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let s = min(max(saturation, 0), 1)
        let v = min(max(value, 0), 1)
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(r: Self.byte(r + m), g: Self.byte(g + m), b: Self.byte(b + m))
    }

    /// Hue and saturation in 0...1 (value is ignored by the lights; brightness is separate).
    public var hueSaturation: (hue: Double, saturation: Double) {
        let r = Double(self.r) / 255, g = Double(self.g) / 255, b = Double(self.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        guard delta > 0 else { return (0, 0) }
        var h: Double
        if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = (b - r) / delta + 2 }
        else { h = (r - g) / delta + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return (h, delta / maxC)
    }

    public var hex: String {
        [r, g, b].hexString.replacingOccurrences(of: " ", with: "")
    }

    /// Gamma 2.8 plus the white-balance scaling the reference library applies (G×100/255, B×140/255),
    /// so that colors on the LEDs match what you picked on screen.
    public func corrected() -> RGB {
        RGB(
            r: Self.gamma[Int(r)],
            g: UInt8(Int(Self.gamma[Int(g)]) * 100 / 255),
            b: UInt8(Int(Self.gamma[Int(b)]) * 140 / 255)
        )
    }

    static let gamma: [UInt8] = (0..<256).map { i in
        UInt8((pow(Double(i) / 255, 2.8) * 255 + 0.5).rounded(.down))
    }

    private static func byte(_ v: Double) -> UInt8 {
        UInt8((min(max(v, 0), 1) * 255).rounded())
    }

    public static let white = RGB(r: 255, g: 255, b: 255)
    public static let warmWhite = RGB(r: 255, g: 180, b: 100)
    public static let red = RGB(r: 255, g: 0, b: 0)
}
