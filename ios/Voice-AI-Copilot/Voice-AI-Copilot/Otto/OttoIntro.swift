import SwiftUI

// Driving intro. Camera looks down the road: vanishing point is at the
// bottom of the screen, the viewer is at the top. The porsche appears
// small at the far end (bottom), grows and accelerates as it comes
// toward the viewer (top), then drives off the top into the splash.

struct OttoDrivingIntro: View {
    var onFinish: () -> Void

    @State private var carProgress: CGFloat = 0   // 0 = far (small, bottom), 1 = near (large, top)
    @State private var roadPhase: CGFloat = 0     // scrolls dashed center line
    @State private var shimmer: CGFloat = 0       // tiny lateral vibration
    @State private var fadeOut: Bool = false

    private let carAspect: CGFloat = 752.0 / 1402.0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width

            // Size grows with perspective: tiny at far (bottom), large near (top).
            let minH: CGFloat = 70
            let maxH: CGFloat = min(h * 0.56, 480)
            let carH = minH + (maxH - minH) * carProgress
            let carW = carH * carAspect

            // Position: bottom → top.
            let startY = h * 0.82         // near vanishing point
            let endY   = -carH * 0.5      // off the top edge
            let y = startY + (endY - startY) * carProgress
            let wobble = sin(shimmer * .pi * 8) * (1.2 + carProgress * 2.5)

            ZStack {
                OttoColor.navyDeep.ignoresSafeArea()

                PerspectiveRoad(phase: roadPhase)
                    .ignoresSafeArea()

                Image("PorscheClipart")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: carW, height: carH)
                    .shadow(color: OttoColor.orange.opacity(0.25 + 0.25 * Double(carProgress)),
                            radius: 28 + 22 * carProgress,
                            x: 0, y: 8 + 14 * carProgress)
                    .position(x: w / 2 + wobble, y: y)
            }
            .opacity(fadeOut ? 0 : 1)
        }
        .task {
            withAnimation(.linear(duration: 0.08).repeatForever(autoreverses: true)) { shimmer = 1 }
            withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) { roadPhase = 1 }

            // Easing: starts slow, accelerates — matches the feeling of a car
            // pulling closer from the distance.
            withAnimation(.timingCurve(0.35, 0.0, 0.65, 1.0, duration: 4.5)) {
                carProgress = 1.0
            }
            try? await Task.sleep(nanoseconds: 4_400_000_000)

            withAnimation(.easeIn(duration: 0.45)) { fadeOut = true }
            try? await Task.sleep(nanoseconds: 450_000_000)
            onFinish()
        }
    }
}

// Perspective road: two side lines converging to a vanishing point at the
// bottom, with dashed center-line segments scrolling outward (toward the
// viewer) to sell forward motion.

struct PerspectiveRoad: View {
    var phase: CGFloat   // 0...1, scrolls the dashes downward

    // Match the reference:
    //  - two softly curved side guides (quadratic beziers bowing outward)
    //  - a single crisp white dashed center line (48pt dashes, 72pt gaps)
    //  - a warm cream radial glow pulsing behind the car
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Warm ambient glow behind the car (slow 4s breathing pulse).
                AmbientGlow()
                    .frame(width: min(w, h) * 0.7, height: min(w, h) * 0.7)
                    .position(x: w / 2, y: h / 2)

                // Side guide curves — bow outward toward the bottom like the
                // reference `M 180 0 Q 140 200 60 400` lines.
                Canvas { ctx, size in
                    let cx = size.width / 2
                    let topOffset: CGFloat = size.width * 0.12
                    let bottomOffset: CGFloat = size.width * 0.48
                    let controlOffset: CGFloat = size.width * 0.18
                    let guideColor = GraphicsContext.Shading.color(Color.white.opacity(0.08))

                    var left = Path()
                    left.move(to: CGPoint(x: cx - topOffset, y: 0))
                    left.addQuadCurve(
                        to: CGPoint(x: cx - bottomOffset, y: size.height),
                        control: CGPoint(x: cx - controlOffset, y: size.height * 0.5)
                    )
                    ctx.stroke(left, with: guideColor, lineWidth: 1.5)

                    var right = Path()
                    right.move(to: CGPoint(x: cx + topOffset, y: 0))
                    right.addQuadCurve(
                        to: CGPoint(x: cx + bottomOffset, y: size.height),
                        control: CGPoint(x: cx + controlOffset, y: size.height * 0.5)
                    )
                    ctx.stroke(right, with: guideColor, lineWidth: 1.5)
                }

                // Center dashed line — 48pt dashes on a 120pt repeat. Scroll
                // downward continuously by offsetting the dash pattern.
                CenterDashes(phase: phase)
                    .frame(width: 3, height: h + 240)
                    .position(x: w / 2, y: h / 2)
            }
        }
    }
}

private struct AmbientGlow: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = 0.9 + 0.1 * sin(t * .pi / 2)          // 4s period
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 240/255, green: 210/255, blue: 180/255).opacity(0.15),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .scaleEffect(pulse)
                .blur(radius: 18)
        }
    }
}

// Single white dashed line scrolling downward. The phase value (0...1) is
// driven by a repeating animation on the parent; we turn it into a vertical
// offset within a 120pt repeat pattern so dashes stream continuously.
private struct CenterDashes: View {
    var phase: CGFloat
    private let dashLength: CGFloat = 48
    private let gapLength: CGFloat = 72
    private var repeatLength: CGFloat { dashLength + gapLength }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let offset = phase.truncatingRemainder(dividingBy: 1.0) * repeatLength

            Canvas { ctx, size in
                let shading = GraphicsContext.Shading.color(Color.white.opacity(0.85))
                var y = -repeatLength + offset
                while y < h + repeatLength {
                    var dash = Path()
                    dash.move(to: CGPoint(x: size.width / 2, y: y))
                    dash.addLine(to: CGPoint(x: size.width / 2, y: y + dashLength))
                    ctx.stroke(dash, with: shading, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                    y += repeatLength
                }
            }
            .shadow(color: Color.white.opacity(0.25), radius: 6)
        }
    }
}
