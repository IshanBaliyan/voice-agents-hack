import SwiftUI

// MARK: - Ambient Background
// Same atmosphere as the new design language — drifting cool fog blobs over a
// midnight indigo base. Aliased to OttoAtmosphere so old call sites keep
// resolving.

struct AmbientBackground: View {
    var body: some View {
        OttoAtmosphere()
    }
}

// MARK: - Voice Waveform line (transcript-adjacent visualizer)
// Used under the live transcript while listening — a row of breathing bars.

struct OttoWaveLine: View {
    var bars: Int = 28
    var color: Color = OttoColor.fog2
    var active: Bool = true
    var width: CGFloat = 240
    var height: CGFloat = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let base = 0.3 + 0.7 * abs(sin(Double(i) * 0.6) * cos(Double(i) * 0.25))
                    let pulse = active ? (0.7 + 0.3 * sin(t * 3 + Double(i) * 0.4)) : 1.0
                    let h = max(2.0, base * pulse * Double(height))
                    Capsule()
                        .fill(color.opacity(0.4 + base * 0.5))
                        .frame(width: max(2, (width - CGFloat(bars - 1) * 3) / CGFloat(bars)), height: CGFloat(h))
                }
            }
            .frame(width: width, height: height)
        }
    }
}

// MARK: - Speaking bars (stacked inside the orb)

struct OttoSpeakingBars: View {
    var color: Color = .white
    var count: Int = 5
    var size: CGFloat = 64

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.08) {
                ForEach(0..<count, id: \.self) { i in
                    let v = 0.4 + 0.6 * abs(sin(t * 5 + Double(i) * 0.7))
                    Capsule()
                        .fill(color)
                        .frame(width: size * 0.12, height: size * v)
                }
            }
            .frame(width: size * 1.3, height: size)
        }
    }
}

// MARK: - HUD wrapper (legacy — used by ActiveSessionView through HudWrapper)
// Kept for compatibility with existing call sites; renders the new BreathingOrb.

struct HudWrapper: View {
    var isRecording: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            BreathingOrb(state: isRecording ? .listening : .idle, size: 220)
                .frame(width: 320, height: 320)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Nav Bar (6-tab pill)
//
// Styled to match the "Otto · Liquid glass nav" component in Otto Nav Bar
// _Offline_.html. Cyan radial glow for the active tab, 48%-cream icons for
// inactive, backdrop-blur over a navy gradient pill.

struct GlassNavBar: View {
    enum Item: Hashable { case home, guide, exploded, history, training, profile }

    var highlighted: Item = .home
    var onSelect: (Item) -> Void

    // Design palette from the HTML export.
    private static let cyanActive  = Color(red: 155/255, green: 228/255, blue: 255/255)   // #9BE4FF
    private static let cyanMid     = Color(red: 111/255, green: 204/255, blue: 234/255)   // #6FCCEA
    private static let iconActive  = Color(red: 234/255, green: 247/255, blue: 255/255)   // #EAF7FF
    private static let iconIdle    = Color(red: 232/255, green: 238/255, blue: 248/255)   // #E8EEF8 @ 48%
    private static let pillStart   = Color(red: 40/255,  green: 58/255,  blue: 96/255)    // rgba(40,58,96,0.42)
    private static let pillEnd     = Color(red: 14/255,  green: 22/255,  blue: 40/255)    // rgba(14,22,40,0.68)
    private static let pillStroke  = Color(red: 180/255, green: 210/255, blue: 255/255)   // rgba(180,210,255,0.14)

    var body: some View {
        HStack(spacing: 0) {
            navButton(.home,     icon: "mic")
            Spacer(minLength: 0)
            navButton(.guide,    icon: "book")
            Spacer(minLength: 0)
            navButton(.exploded, icon: "square.stack.3d.up")
            Spacer(minLength: 0)
            navButton(.history,  icon: "graduationcap")
            Spacer(minLength: 0)
            navButton(.training, icon: "arkit")
            Spacer(minLength: 0)
            navButton(.profile,  icon: "person")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .background(
            Capsule()
                .fill(LinearGradient(
                    colors: [Self.pillStart.opacity(0.42), Self.pillEnd.opacity(0.68)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        // Top highlight sheen approximating the ::before gradient in the HTML.
        .overlay(
            Capsule()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.09), Color.clear],
                    startPoint: .top, endPoint: .center))
                .blendMode(.screen)
                .padding(1)
                .allowsHitTesting(false)
        )
        .overlay(
            Capsule().stroke(Self.pillStroke.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.75), radius: 30, x: 0, y: 20)
    }

    @ViewBuilder
    private func navButton(_ item: Item, icon: String) -> some View {
        let isActive = item == highlighted
        Button { onSelect(item) } label: {
            ZStack {
                if isActive {
                    Circle()
                        .fill(RadialGradient(
                            colors: [
                                Self.cyanActive.opacity(0.38),
                                Self.cyanMid.opacity(0.18),
                                Color(red: 30/255, green: 60/255, blue: 100/255).opacity(0.25)
                            ],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 2, endRadius: 23))
                        .overlay(Circle().stroke(Self.cyanActive.opacity(0.45), lineWidth: 1))
                        .shadow(color: Self.cyanActive.opacity(0.35), radius: 14)
                        .frame(width: 42, height: 42)
                }
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isActive ? Self.iconActive : Self.iconIdle.opacity(0.48))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
