import SwiftUI

// MARK: - Palette
// Cool, atmospheric palette — frosted glass on midnight indigo. Replaces the
// earlier cream/orange scheme. Names of the older tokens are kept so existing
// call sites continue to compile; their RGB values now resolve to the new
// frosted-glass equivalents.

enum OttoColor {
    // Background base
    static let bg0        = Color(red: 0x0B/255, green: 0x12/255, blue: 0x20/255)   // deep midnight #0B1220
    static let bg1        = Color(red: 0x11/255, green: 0x1B/255, blue: 0x30/255)
    static let bg2        = Color(red: 0x1A/255, green: 0x27/255, blue: 0x42/255)   // indigo #1A2742

    // Fog / mist tints
    static let fog1       = Color(red: 0x5B/255, green: 0x8B/255, blue: 0xD4/255)   // periwinkle #5B8BD4
    static let fog2       = Color(red: 0x6F/255, green: 0xCC/255, blue: 0xEA/255)   // cyan
    static let fog3       = Color(red: 0xA9/255, green: 0xB8/255, blue: 0xD8/255)   // mist  #A9B8D8

    // Ink (text on dark)
    static let ink        = Color(red: 0xE8/255, green: 0xEE/255, blue: 0xF8/255)   // #E8EEF8
    static let ink2       = Color(red: 0xE8/255, green: 0xEE/255, blue: 0xF8/255).opacity(0.72)
    static let ink3       = Color(red: 0xE8/255, green: 0xEE/255, blue: 0xF8/255).opacity(0.48)
    static let ink4       = Color(red: 0xE8/255, green: 0xEE/255, blue: 0xF8/255).opacity(0.28)

    // Accents
    static let accent     = Color(red: 0x7F/255, green: 0xB8/255, blue: 0xFF/255)   // sky #7FB8FF
    static let accentWarm = Color(red: 0x9B/255, green: 0xE4/255, blue: 0xFF/255)   // cyan #9BE4FF
    static let danger     = Color(red: 0xFF/255, green: 0x8A/255, blue: 0x8A/255)

    // Backwards-compatible aliases — the old code uses these names everywhere.
    // Map them to the closest equivalents in the new palette so existing views
    // keep compiling without breaking visuals.
    static let navyDeep   = bg0
    static let navy       = bg2
    static let navyCard   = bg2
    static let cream      = ink
    static let creamDim   = ink2
    static let creamFaint = ink3
    static let hairline   = Color.white.opacity(0.06)
    static let orange     = accentWarm   // accent color — now cyan, not orange
    static let orangeDim  = accentWarm.opacity(0.55)
    static let orbBlue    = fog1
    static let orbBlueDeep = bg2
    static let orbBlueGlow = accentWarm
}

enum OttoFont {
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Atmosphere
// Foggy gradient background used across every screen. A radial midnight base
// with three drifting fog blobs, plus a subtle film grain. Animated by default.

struct OttoBackground: View {
    var body: some View { OttoAtmosphere() }
}

struct OttoAtmosphere: View {
    var hue: Double = 210
    var animated: Bool = true

    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            // Radial base — indigo at top, midnight in the middle, near-black bottom.
            RadialGradient(
                colors: [
                    Color(hue: hue/360, saturation: 0.45, brightness: 0.18),
                    OttoColor.bg0,
                    Color(red: 0x05/255, green: 0x09/255, blue: 0x11/255)
                ],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 700
            )

            // Drifting fog blobs.
            DriftingBlob(color: Color(hue: (hue + 10)/360, saturation: 0.8, brightness: 0.7).opacity(0.22),
                         pos: UnitPoint(x: 0.30, y: 0.10),
                         size: 1.05,
                         speed: 22,
                         animated: animated)
            DriftingBlob(color: Color(hue: (hue + 30)/360, saturation: 0.85, brightness: 0.65).opacity(0.18),
                         pos: UnitPoint(x: 0.78, y: 0.78),
                         size: 0.95,
                         speed: 28,
                         animated: animated)
            DriftingBlob(color: Color(hue: (hue - 20)/360, saturation: 0.7, brightness: 0.55).opacity(0.12),
                         pos: UnitPoint(x: 0.5, y: 0.55),
                         size: 0.85,
                         speed: 34,
                         animated: animated)

            // Film grain.
            Rectangle()
                .fill(Color.white.opacity(0.02))
                .blendMode(.overlay)
        }
        .ignoresSafeArea()
    }
}

private struct DriftingBlob: View {
    var color: Color
    var pos: UnitPoint
    var size: CGFloat
    var speed: Double
    var animated: Bool
    @State private var t: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let dx = sin(t * .pi * 2) * 0.04
            let dy = cos(t * .pi * 2) * 0.04
            Circle()
                .fill(color)
                .frame(width: w * size * 1.2, height: h * size * 0.8)
                .blur(radius: 60)
                .position(x: w * (pos.x + dx), y: h * (pos.y + dy))
                .onAppear {
                    guard animated else { return }
                    withAnimation(.easeInOut(duration: speed).repeatForever(autoreverses: true)) {
                        t = 1
                    }
                }
        }
    }
}

// MARK: - Frosted glass card with neumorphic edge

struct OttoCard<Content: View>: View {
    var padding: CGFloat = 18
    var corner: CGFloat = 24
    var pressed: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(
                        colors: pressed
                            ? [Color(red: 10/255, green: 18/255, blue: 32/255).opacity(0.85),
                               Color(red: 20/255, green: 30/255, blue: 50/255).opacity(0.6)]
                            : [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.55),
                               Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(OttoColor.fog3.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(pressed ? 0.0 : 0.45), radius: 18, x: 0, y: 12)
    }
}

// HairlineCard — kept for backwards compatibility; styled like OttoCard now.
struct HairlineCard<Content: View>: View {
    var padding: CGFloat = 16
    var corner: CGFloat = 22
    @ViewBuilder var content: () -> Content
    var body: some View {
        OttoCard(padding: padding, corner: corner, content: content)
    }
}

// MARK: - Eyebrow label (uppercase tracked, mono)

struct Label2Mono: View {
    let text: String
    var size: CGFloat = 10
    var color: Color = OttoColor.ink4
    var body: some View {
        Text(text.uppercased())
            .font(OttoFont.mono(size, weight: .medium))
            .tracking(2.4)
            .foregroundStyle(color)
    }
}

// MARK: - Otto wordmark — "otto" + cyan dot

struct OttoWordmark: View {
    var size: CGFloat = 56
    var showDot: Bool = true

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("otto")
                .font(.system(size: size, weight: .light, design: .default))
                .kerning(-0.5)
                .foregroundStyle(OttoColor.ink)
            if showDot {
                Circle()
                    .fill(LinearGradient(
                        colors: [OttoColor.fog2, OttoColor.fog1],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size * 0.18, height: size * 0.18)
                    .shadow(color: OttoColor.fog2.opacity(0.7), radius: size * 0.4)
                    .offset(y: -size * 0.05)
            }
        }
    }
}

// MARK: - Top bar pill — wordmark optional, vehicle + battery pill

struct OttoTopBar: View {
    var vehicle: String = "2018 Honda Civic"
    var battery: Int = 96
    var showWordmark: Bool = true

    var body: some View {
        HStack {
            if showWordmark {
                OttoWordmark(size: 22, showDot: true)
            } else {
                Color.clear.frame(width: 1, height: 22)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(OttoColor.fog2)
                    .frame(width: 6, height: 6)
                    .shadow(color: OttoColor.fog2, radius: 4)
                Text(vehicle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OttoColor.ink)
                    .kerning(0.2)
                Text("\(battery)%")
                    .font(OttoFont.mono(10, weight: .regular))
                    .foregroundStyle(OttoColor.ink3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule().stroke(OttoColor.fog3.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Eyebrow (mirrors the JSX OttoEyebrow)

struct OttoEyebrow: View {
    let text: String
    var color: Color = OttoColor.ink4
    var size: CGFloat = 10

    var body: some View {
        Text(text.uppercased())
            .font(OttoFont.mono(size, weight: .medium))
            .tracking(2.4)
            .foregroundStyle(color)
    }
}

// MARK: - Glass chip (suggestion / inline action)

struct OttoChip: View {
    let text: String
    var active: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(OttoColor.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .background(
                Capsule().fill(
                    active
                    ? LinearGradient(colors: [OttoColor.fog2.opacity(0.20), OttoColor.fog1.opacity(0.20)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.55),
                                              Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .overlay(
                Capsule().stroke(active ? OttoColor.fog2.opacity(0.55) : OttoColor.fog3.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: active ? OttoColor.fog2.opacity(0.35) : .black.opacity(0.2), radius: active ? 12 : 6, x: 0, y: 4)
    }
}

// MARK: - Neumorphic circle (back button, mic shortcut)

struct OttoNeuCircle<Content: View>: View {
    var size: CGFloat = 44
    var active: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 40/255, green: 58/255, blue: 92/255).opacity(0.7),
                             Color(red: 18/255, green: 28/255, blue: 48/255).opacity(0.9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .stroke(OttoColor.fog3.opacity(0.10), lineWidth: 1)
            content()
        }
        .frame(width: size, height: size)
        .shadow(color: active ? OttoColor.fog2.opacity(0.45) : .black.opacity(0.45),
                radius: active ? 20 : 10, x: 0, y: active ? 0 : 6)
    }
}

// Keep a no-op grid shim — some old screens reference GridBackground.
struct GridBackground: View {
    var spacing: CGFloat = 28
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(OttoColor.fog3.opacity(0.05))
            var x: CGFloat = 0
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: stroke, lineWidth: 0.5)
                x += spacing
            }
            var y: CGFloat = 0
            while y < size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: stroke, lineWidth: 0.5)
                y += spacing
            }
        }
    }
}
