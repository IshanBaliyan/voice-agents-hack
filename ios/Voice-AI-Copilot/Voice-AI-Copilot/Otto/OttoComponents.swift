import SwiftUI

// MARK: - Breathing Orb
// Visual indicator of the real voice state. It's the user's only way to know
// whether the mic is live, the model is thinking, or TTS is playing.

struct BreathingOrb: View {
    var state: VoiceState
    var size: CGFloat = 180

    private var intensity: Double {
        switch state {
        case .idle:      return 0.55
        case .listening: return 1.15
        case .thinking:  return 0.85
        case .speaking:  return 1.35
        }
    }

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [OttoColor.orbBlueGlow.opacity(0.55), .clear],
                        center: .center, startRadius: size * 0.2, endRadius: size * 0.95
                    )
                )
                .frame(width: size * 1.85, height: size * 1.85)
                .blur(radius: 30)

            // Hairline rings
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(OttoColor.orbBlue.opacity(0.18 - Double(i) * 0.05), lineWidth: 1)
                    .frame(width: size * (1.05 + CGFloat(i) * 0.22),
                           height: size * (1.05 + CGFloat(i) * 0.22))
            }

            // Flowing liquid core
            FlowingOrbCore(size: size, intensity: intensity)

            // Microphone glyph
            Image(systemName: micIcon)
                .font(.system(size: size * 0.3, weight: .medium))
                .foregroundStyle(Color.white)
                .shadow(color: OttoColor.orbBlueDeep.opacity(0.8), radius: 6)
        }
    }

    private var micIcon: String {
        switch state {
        case .idle:      return "mic.fill"
        case .listening: return "mic.fill"
        case .thinking:  return "mic.fill"
        case .speaking:  return "waveform"
        }
    }
}

// Flowing blue orb using TimelineView + Canvas.
// Renders overlapping sine-wave "metaballs" that drift, giving a liquid look.
struct FlowingOrbCore: View {
    let size: CGFloat
    let intensity: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            orbStack(t: t)
        }
    }

    private func orbStack(t: TimeInterval) -> some View {
        ZStack {
            baseSphere
            blobLayer(t: t)
            waveLayer(t: t)
            glossLayer
            edgeStroke
        }
        .scaleEffect(1.0 + CGFloat(sin(t * 1.1)) * 0.02 * intensity)
    }

    private var baseSphere: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [OttoColor.orbBlueGlow, OttoColor.orbBlue, OttoColor.orbBlueDeep],
                    center: UnitPoint(x: 0.35, y: 0.30),
                    startRadius: 2,
                    endRadius: size * 0.62
                )
            )
            .frame(width: size, height: size)
            .shadow(color: OttoColor.orbBlue.opacity(0.6), radius: 28)
    }

    private func blobLayer(t: TimeInterval) -> some View {
        Canvas { gctx, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let cx = w / 2
            let cy = h / 2
            for i in 0..<4 {
                let phase = t * (0.6 + Double(i) * 0.18) + Double(i) * 1.7
                let radius = Double(size) * (0.28 + 0.08 * sin(phase * 1.3))
                let ox = CGFloat(cos(phase) * Double(size) * 0.18)
                let oy = CGFloat(sin(phase * 1.1) * Double(size) * 0.18)
                let r = CGFloat(radius)
                let rect = CGRect(x: cx + ox - r, y: cy + oy - r, width: r * 2, height: r * 2)
                let color: Color = (i % 2 == 0) ? OttoColor.orbBlueGlow : OttoColor.orbBlueDeep
                gctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.45 * intensity)))
            }
        }
        .frame(width: size, height: size)
        .blur(radius: size * 0.10)
        .mask(Circle().frame(width: size, height: size))
    }

    private func waveLayer(t: TimeInterval) -> some View {
        Canvas { gctx, canvasSize in
            let path = Self.buildWavePath(in: canvasSize, t: t, intensity: intensity)
            let shading = GraphicsContext.Shading.color(OttoColor.orbBlueDeep.opacity(0.35))
            gctx.fill(path, with: shading)
        }
        .frame(width: size, height: size)
        .mask(Circle().frame(width: size, height: size))
    }

    private static func buildWavePath(in canvasSize: CGSize, t: TimeInterval, intensity: Double) -> Path {
        var path = Path()
        let w = canvasSize.width
        let h = canvasSize.height
        let baseY = h * 0.55
        let amp = h * 0.06 * intensity
        let freq = 2.1
        path.move(to: CGPoint(x: 0, y: baseY))
        var x: CGFloat = 0
        while x <= w {
            let ratio = Double(x / w)
            let phase = ratio * .pi * 2 * freq + t * 1.6
            let y = baseY + CGFloat(sin(phase)) * amp
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }

    private var glossLayer: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.35), .clear],
                    startPoint: .top, endPoint: .center
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 4)
    }

    private var edgeStroke: some View {
        Circle()
            .stroke(OttoColor.orbBlueGlow.opacity(0.6), lineWidth: 1)
            .frame(width: size, height: size)
    }
}

struct SpeakingBars: View {
    var color: Color
    var count: Int = 5
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: geo.size.width / CGFloat(count * 3)) {
                ForEach(0..<count, id: \.self) { i in
                    let t = phase + CGFloat(i) * 0.4
                    let h = (0.45 + 0.55 * abs(sin(t))) * geo.size.height
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width / CGFloat(count * 2), height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Circular Icon Button
// Used only where a tap is the fastest path (camera toggle, close session).

struct FloatingIconButton: View {
    let systemName: String
    var filled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(filled ? OttoColor.orange : Color.clear)
                Circle().stroke(filled ? Color.clear : OttoColor.hairline, lineWidth: 1)
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(filled ? OttoColor.navyDeep : OttoColor.cream)
            }
            .frame(width: 48, height: 48)
            .shadow(color: filled ? OttoColor.orange.opacity(0.45) : .clear, radius: 16)
        }
        .buttonStyle(.plain)
    }
}
