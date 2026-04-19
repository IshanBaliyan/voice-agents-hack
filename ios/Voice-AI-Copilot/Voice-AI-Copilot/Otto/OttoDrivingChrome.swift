import SwiftUI

// Animated mesh gradient for the driving intro. Cool navy base with warm
// orange flares that drift as the car progresses up the screen.

struct DrivingMeshBackground: View {
    var progress: CGFloat   // 0...1, the car's drive progress

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            MeshBackdrop(
                progress: progress,
                time: ctx.date.timeIntervalSinceReferenceDate
            )
        }
    }
}

private struct MeshBackdrop: View {
    let progress: CGFloat
    let time: TimeInterval

    var body: some View {
        let drift = Float(sin(time * 0.6)) * 0.05
        let warmth = 0.15 + 0.35 * Double(progress)

        MeshGradient(
            width: 3,
            height: 3,
            points: buildPoints(drift: drift),
            colors: buildColors(warmth: warmth)
        )
    }

    private func buildPoints(drift: Float) -> [SIMD2<Float>] {
        [
            SIMD2(0.0, 0.0),
            SIMD2(0.5 + drift, 0.0),
            SIMD2(1.0, 0.0),
            SIMD2(0.0, 0.5 - drift * 0.5),
            SIMD2(0.5, 0.5 + drift),
            SIMD2(1.0, 0.5 + drift * 0.8),
            SIMD2(0.0, 1.0),
            SIMD2(0.5 - drift, 1.0),
            SIMD2(1.0, 1.0)
        ]
    }

    private func buildColors(warmth: Double) -> [Color] {
        let mid = Color(red: 0.12, green: 0.16, blue: 0.28)
        let midR = Color(red: 0.10, green: 0.14, blue: 0.26)
        let dim = Color(red: 0.08, green: 0.10, blue: 0.20)
        let dark = Color(red: 0.05, green: 0.06, blue: 0.14)
        return [
            OttoColor.navyDeep, dim, OttoColor.navyDeep,
            mid, OttoColor.orange.opacity(warmth), midR,
            OttoColor.navyDeep, dark, OttoColor.navyDeep
        ]
    }
}

// Glass HUD panel that sits at the bottom of the driving intro. Uses
// ultraThinMaterial for the frosted look, with a gradient stroke as a
// highlight along the top edge.

struct GlassDrivingPanel: View {
    var progress: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            // Pulsing live indicator
            ZStack {
                Circle()
                    .fill(OttoColor.orange.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .blur(radius: 6)
                Circle()
                    .fill(OttoColor.orange)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Otto is on the way")
                    .font(OttoFont.body(13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text("WARMING UP · \(Int(progress * 100))%")
                    .font(OttoFont.mono(10, weight: .regular))
                    .tracking(2.2)
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            Spacer(minLength: 0)

            // Tiny animated signal bars, just for life
            SignalBars(progress: progress)
                .frame(width: 28, height: 22)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(height: 76)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.5), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 12)
    }
}

private struct SignalBars: View {
    var progress: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    barHeight(index: i, t: t)
                }
            }
        }
    }

    private func barHeight(index i: Int, t: TimeInterval) -> some View {
        let phase = t * 3.2 + Double(i) * 0.8
        let base = 0.3 + 0.7 * Double(progress)
        let h = (0.35 + 0.5 * abs(sin(phase))) * base
        return Capsule()
            .fill(OttoColor.orange.opacity(0.85))
            .frame(width: 4, height: CGFloat(h) * 22)
    }
}
