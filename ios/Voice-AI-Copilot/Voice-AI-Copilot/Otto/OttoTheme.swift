import SwiftUI

enum OttoColor {
    static let navyDeep   = Color(red: 36/255,  green: 43/255,  blue: 60/255)   // matches otto-v3-dark.png bg
    static let navy       = Color(red: 46/255,  green: 54/255,  blue: 74/255)
    static let navyCard   = Color(red: 56/255,  green: 65/255,  blue: 86/255)
    static let cream      = Color(red: 0.910, green: 0.890, blue: 0.835)
    static let creamDim   = Color(red: 0.910, green: 0.890, blue: 0.835).opacity(0.60)
    static let creamFaint = Color(red: 0.910, green: 0.890, blue: 0.835).opacity(0.32)
    static let hairline   = Color(red: 0.910, green: 0.890, blue: 0.835).opacity(0.14)
    static let orange     = Color(red: 0.918, green: 0.540, blue: 0.235)
    static let orangeDim  = Color(red: 0.918, green: 0.540, blue: 0.235).opacity(0.55)
    static let orbBlue    = Color(red: 0.38, green: 0.60, blue: 1.00)
    static let orbBlueDeep = Color(red: 0.10, green: 0.25, blue: 0.70)
    static let orbBlueGlow = Color(red: 0.55, green: 0.78, blue: 1.00)
    static let danger     = Color(red: 0.900, green: 0.320, blue: 0.320)
}

enum OttoFont {
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

struct OttoBackground: View {
    var body: some View {
        ZStack {
            OttoColor.navyDeep.ignoresSafeArea()
            GridBackground()
                .opacity(0.35)
                .ignoresSafeArea()
        }
    }
}

struct GridBackground: View {
    var spacing: CGFloat = 28
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(OttoColor.cream.opacity(0.05))
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

struct HairlineCard<Content: View>: View {
    var padding: CGFloat = 16
    var corner: CGFloat = 22
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(OttoColor.navy.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(OttoColor.hairline, lineWidth: 1)
            )
    }
}

struct Label2Mono: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = OttoColor.creamFaint
    var body: some View {
        Text(text.uppercased())
            .font(OttoFont.mono(size, weight: .medium))
            .tracking(2)
            .foregroundStyle(color)
    }
}
