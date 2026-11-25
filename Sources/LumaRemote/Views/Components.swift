import SwiftUI
import LumaCore

extension View {
    /// Soft light-emitting glow in `color`: a tight bright halo plus a wide soft bloom, so it reads
    /// as light rather than a drop shadow. A no-op (transparent shadows, same view identity) when
    /// `!isActive`.
    func glow(_ color: Color, radius: CGFloat = 10, isActive: Bool = true) -> some View {
        self
            .shadow(color: isActive ? color.opacity(0.85) : .clear, radius: radius * 0.3)
            .shadow(color: isActive ? color.opacity(0.5) : .clear, radius: radius)
    }
}

extension RGB {
    var color: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

extension LightState {
    /// What the light looks like, for previews and list dots.
    var displayColor: Color {
        guard isOn else { return Color(white: 0.25) }
        switch mode {
        case .color(let c): return c.color
        case .white(let w): return Encoder.approximateWhite(warmth: w).color
        case .effect(let e): return e.swatch?.color ?? .purple
        }
    }

    var isEffect: Bool {
        if case .effect = mode { return true }
        return false
    }

    var summary: String {
        guard isOn else { return "Off" }
        switch mode {
        case .color: return "\(brightness)%"
        case .white(let w): return "\(w > 0.66 ? "Warm" : w < 0.33 ? "Cool" : "Neutral") white · \(brightness)%"
        case .effect(let e): return "\(e.name) · \(brightness)%"
        }
    }
}

/// A glowing dot showing a light's current look. Multicolor effects get a rainbow with a rainbow
/// glow. Off lights don't glow; dim lights glow less.
struct LightDot: View {
    var state: LightState
    var size: CGFloat = 28

    private var isRainbow: Bool {
        if state.isOn, case .effect(let e) = state.mode, e.swatch == nil { return true }
        return false
    }

    /// Glow strength follows brightness, but never fades out entirely while the light is on.
    private var glowStrength: Double { 0.45 + 0.55 * Double(min(max(state.brightness, 0), 100)) / 100 }

    var body: some View {
        ZStack {
            if isRainbow {
                // A blurred copy of the gradient behind the dot: a shadow can only take one color.
                Circle()
                    .fill(AngularGradient(colors: Self.rainbow, center: .center))
                    .blur(radius: size / 4)
                    .opacity(0.9 * glowStrength)
                Circle().fill(AngularGradient(colors: Self.rainbow, center: .center))
            } else {
                Circle()
                    .fill(state.displayColor)
                    .glow(state.displayColor.opacity(glowStrength), radius: size / 2.5, isActive: state.isOn)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.15)))
    }

    static let rainbow: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
        Color(hue: $0, saturation: 0.9, brightness: 1)
    }
}

/// A tappable color circle with glow; selected = white ring + stronger glow.
struct ColorSwatch: View {
    var rgb: RGB
    var isSelected: Bool
    var size: CGFloat = 32
    var action: () -> Void

    init(rgb: RGB, isSelected: Bool, size: CGFloat = 32, action: @escaping () -> Void) {
        self.rgb = rgb
        self.isSelected = isSelected
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(rgb.color)
                .frame(width: size, height: size)
                .glow(rgb.color, radius: isSelected ? size / 2 : size / 5)
                .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 3 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected) { _, nowSelected in nowSelected }
        .accessibilityLabel("Color #\(rgb.hex)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Grid palette: a row of whites (cool → warm) on top, then 12 hues across × 5 rows going from
/// pastel to fully saturated. Rounded-square cells fill the width; the selected cell gets a white
/// ring and a stronger glow.
struct ColorGrid: View {
    var selected: RGB?
    var onSelect: (RGB) -> Void

    init(selected: RGB?, onSelect: @escaping (RGB) -> Void) {
        self.selected = selected
        self.onSelect = onSelect
    }

    static let hueCount = 12
    static let saturations: [Double] = [0.2, 0.4, 0.6, 0.8, 1.0]

    /// Row-major palette, every row `hueCount` wide.
    static let palette: [RGB] = {
        let whites = (0..<hueCount).map { Encoder.approximateWhite(warmth: Double($0) / Double(hueCount - 1)) }
        let hues = saturations.flatMap { s in
            (0..<hueCount).map { RGB(hue: Double($0) / Double(hueCount), saturation: s) }
        }
        return whites + hues
    }()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: ColorGrid.hueCount)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, rgb in
                cell(rgb)
            }
        }
        .padding(8)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func cell(_ rgb: RGB) -> some View {
        let isSelected = rgb == selected
        return Button { onSelect(rgb) } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rgb.color)
                .aspectRatio(1, contentMode: .fit)
                .glow(rgb.color, radius: isSelected ? 12 : 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white, lineWidth: isSelected ? 2.5 : 0)
                )
                .scaleEffect(isSelected ? 1.12 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityLabel("Color #\(rgb.hex)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A preset chip for a horizontal presets row: a glowing dot of the preset's look and its name.
struct PresetChip: View {
    var preset: LightPreset
    var isActive: Bool = false
    var memberIDs: [UUID] = []
    var action: () -> Void

    init(preset: LightPreset, isActive: Bool = false, memberIDs: [UUID] = [], action: @escaping () -> Void) {
        self.preset = preset
        self.isActive = isActive
        self.memberIDs = memberIDs
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                LightCluster(states: preset.previewStates(memberIDs: memberIDs), size: 30)
                    .frame(height: 34)
                Text(preset.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(width: 72)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : .white.opacity(0.06), lineWidth: isActive ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preset \(preset.name)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Hue (angle) + saturation (radius) wheel. Brightness is a separate slider because the lights
/// treat it separately.
struct ColorWheel: View {
    var color: RGB?
    var onChange: (RGB) -> Void

    @State private var knob: (hue: Double, saturation: Double)?

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let current = knob ?? color?.hueSaturation ?? (0, 0)
            ZStack {
                Circle().fill(AngularGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                    center: .center
                ))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                let knobColor = RGB(hue: current.hue, saturation: current.saturation).color
                Circle()
                    .fill(knobColor)
                    .frame(width: 34, height: 34)
                    .glow(knobColor, radius: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 1.5)
                    .offset(
                        x: cos(current.hue * 2 * .pi) * current.saturation * (radius - 17),
                        y: sin(current.hue * 2 * .pi) * current.saturation * (radius - 17)
                    )
                    .opacity(color == nil && knob == nil ? 0 : 1)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.location.x - geo.size.width / 2
                    let dy = value.location.y - geo.size.height / 2
                    var hue = atan2(dy, dx) / (2 * .pi)
                    if hue < 0 { hue += 1 }
                    let saturation = min(hypot(dx, dy) / (radius - 17), 1)
                    knob = (hue, saturation)
                    onChange(RGB(hue: hue, saturation: saturation))
                }
                .onEnded { _ in knob = nil }
            )
            .sensoryFeedback(.selection, trigger: knob == nil)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A large, glowing power button.
struct PowerButton: View {
    var isOn: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isOn ? .black : .white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(isOn ? tint : Color(white: 0.2)))
                .glow(tint, radius: 22, isActive: isOn)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact, trigger: isOn)
        .accessibilityLabel(isOn ? "Turn off" : "Turn on")
    }
}

/// Thick brightness slider with a sun icon, dragged anywhere along its length.
struct BrightnessSlider: View {
    var value: Int
    var tint: Color
    var onChange: (Int) -> Void

    @State private var dragValue: Int?

    var body: some View {
        let shown = dragValue ?? value
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.18))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(56, geo.size.width * CGFloat(shown) / 100))
                    .glow(
                        tint.opacity(0.35 + 0.65 * Double(shown) / 100),
                        radius: 4 + 12 * CGFloat(shown) / 100
                    )
                HStack {
                    Image(systemName: "sun.max.fill")
                    Spacer()
                    Text("\(shown)%").monospacedDigit()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .blendMode(.difference)
                .padding(.horizontal, 18)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let v = Int((drag.location.x / geo.size.width * 100).rounded())
                    let clamped = min(max(v, 1), 100)
                    if clamped != dragValue {
                        dragValue = clamped
                        onChange(clamped)
                    }
                }
                .onEnded { _ in dragValue = nil }
            )
        }
        .frame(height: 56)
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(shown) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 10, 100))
            case .decrement: onChange(max(value - 10, 1))
            @unknown default: break
            }
        }
    }
}

/// Cool ↔ warm white slider, painted with the actual range of whites.
struct WarmthSlider: View {
    var warmth: Double
    var onChange: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let shown = dragValue ?? warmth
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 0.25).map { Encoder.approximateWhite(warmth: $0).color },
                    startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(Encoder.approximateWhite(warmth: shown).color)
                    .frame(width: 44, height: 44)
                    .glow(Encoder.approximateWhite(warmth: shown).color, radius: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 1.5)
                    .offset(x: (geo.size.width - 52) * shown + 4)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let v = min(max((drag.location.x - 26) / (geo.size.width - 52), 0), 1)
                    dragValue = v
                    onChange(v)
                }
                .onEnded { _ in dragValue = nil }
            )
        }
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            HStack { Text("Cool"); Spacer(); Text("Warm") }
                .font(.caption).foregroundStyle(.secondary).offset(y: 20)
        }
        .padding(.bottom, 20)
        .accessibilityElement()
        .accessibilityLabel("White temperature")
        .accessibilityValue(shown > 0.5 ? "Warm" : "Cool")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(warmth + 0.1, 1))
            case .decrement: onChange(max(warmth - 0.1, 0))
            @unknown default: break
            }
        }
    }
}

/// One glowing dot per distinct look, overlapping like a little bouquet of lights. A single look
/// renders exactly like `LightDot`.
struct LightCluster: View {
    var states: [LightState]
    var size: CGFloat = 28

    var body: some View {
        let shown = Array(states.prefix(4))
        if shown.count <= 1 {
            LightDot(state: shown.first ?? LightState(isOn: false), size: size)
        } else {
            let dot = size * 0.62
            let step = (size * 1.3 - dot) / CGFloat(shown.count - 1)
            ZStack(alignment: .leading) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, state in
                    LightDot(state: state, size: dot)
                        .offset(x: CGFloat(i) * step)
                }
            }
            .frame(width: size * 1.3, height: size, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel("\(shown.count) different looks")
        }
    }
}
