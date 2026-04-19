import SwiftUI

// MARK: - Breathing Orb
// Hero element of the new design language. A frosted glass sphere with a cool
// cyan/periwinkle gradient core, surrounded by concentric breathing rings and
// (when active) outward-rippling hairlines. Mic glyph in idle/listening,
// waveform bars while speaking, orbiting dot while thinking.

struct BreathingOrb: View {
    var state: VoiceState
    var size: CGFloat = 220

    private var ringColor: Color {
        switch state {
        case .speaking:  return OttoColor.accentWarm
        case .listening: return OttoColor.fog2
        default:         return OttoColor.fog1
        }
    }

    private var isActive: Bool { state != .idle }

    var body: some View {
        ZStack {
            // Outer glow pool
            Circle()
                .fill(RadialGradient(
                    colors: [ringColor.opacity(0.35), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.9))
                .frame(width: size * 1.8, height: size * 1.8)
                .blur(radius: 30)

            // Concentric ripple rings (listening / speaking)
            if isActive {
                ForEach(0..<4, id: \.self) { i in
                    RippleRing(color: ringColor, baseSize: size * 0.9, delay: Double(i) * 0.6)
                }
            }

            // Static hairline rings
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(OttoColor.ink4, lineWidth: 1)
                    .opacity(0.5 - Double(i) * 0.1)
                    .frame(width: size * (1.30 - CGFloat(i) * 0.15),
                           height: size * (1.30 - CGFloat(i) * 0.15))
            }

            // Frosted glass sphere
            FrostedSphere(size: size * 0.72, ringColor: ringColor)

            // Glyph
            Group {
                switch state {
                case .speaking:
                    OttoSpeakingBars(color: .white, count: 5, size: size * 0.20)
                case .thinking:
                    OrbitingDot(size: size, color: OttoColor.accentWarm)
                default:
                    Image(systemName: "mic.fill")
                        .font(.system(size: size * 0.18, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.95))
                }
            }
        }
        .frame(width: size * 1.4, height: size * 1.4)
    }
}

// A single ripple ring that scales outward and fades.
private struct RippleRing: View {
    var color: Color
    var baseSize: CGFloat
    var delay: Double

    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.4), lineWidth: 1)
            .frame(width: baseSize, height: baseSize)
            .scaleEffect(animate ? 2.0 : 0.6)
            .opacity(animate ? 0.0 : 0.55)
            .onAppear {
                withAnimation(
                    .timingCurve(0.1, 0.7, 0.3, 1, duration: 2.8)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
                ) {
                    animate = true
                }
            }
    }
}

// A small dot that orbits the orb perimeter — used in `.thinking`.
private struct OrbitingDot: View {
    var size: CGFloat
    var color: Color
    @State private var rotate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color, radius: 8)
                .offset(y: -size * 0.42)
        }
        .frame(width: size * 0.85, height: size * 0.85)
        .rotationEffect(.degrees(rotate ? 360 : 0))
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                rotate = true
            }
        }
    }
}

// Frosted glass sphere — the inner orb, breathes gently.
private struct FrostedSphere: View {
    var size: CGFloat
    var ringColor: Color

    @State private var breathe = false

    var body: some View {
        ZStack {
            // Core gradient
            Circle()
                .fill(RadialGradient(
                    colors: [
                        Color.white.opacity(0.45),
                        ringColor.opacity(0.55),
                        Color(red: 0x1A/255, green: 0x27/255, blue: 0x42/255).opacity(0.95)
                    ],
                    center: UnitPoint(x: 0.30, y: 0.25),
                    startRadius: 2,
                    endRadius: size * 0.7))
                .overlay(
                    // Inner frost shell
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color.white.opacity(0.25), .clear],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: size * 0.55))
                        .blur(radius: 4)
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
        .frame(width: size, height: size)
        .shadow(color: ringColor.opacity(0.45), radius: size * 0.35)
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 18)
        .scaleEffect(breathe ? 1.06 : 1.0)
        .opacity(breathe ? 1.0 : 0.92)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

// MARK: - Speaking bars (legacy alias used in some code)
struct SpeakingBars: View {
    var color: Color
    var count: Int = 5
    var body: some View { OttoSpeakingBars(color: color, count: count, size: 64) }
}

// MARK: - Floating icon button (kept for camera/close)

struct FloatingIconButton: View {
    let systemName: String
    var filled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(filled ? OttoColor.accentWarm : Color.clear)
                Circle().stroke(filled ? Color.clear : OttoColor.fog3.opacity(0.10), lineWidth: 1)
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(filled ? OttoColor.bg0 : OttoColor.ink)
            }
            .frame(width: 48, height: 48)
            .shadow(color: filled ? OttoColor.accentWarm.opacity(0.45) : .clear, radius: 16)
        }
        .buttonStyle(.plain)
    }
}
