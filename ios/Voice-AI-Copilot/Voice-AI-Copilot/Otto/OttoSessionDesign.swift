import SwiftUI

// MARK: - Ambient Background
// Layered radial gradients on near-black, matching the CSS .ambient-bg.

struct AmbientBackground: View {
    private let base = Color(red: 5/255, green: 7/255, blue: 10/255)

    var body: some View {
        ZStack {
            base.ignoresSafeArea()

            // circle at 20% 30%, rgba(40,80,160,0.15)
            RadialGradient(
                colors: [Color(red: 40/255, green: 80/255, blue: 160/255).opacity(0.15), .clear],
                center: UnitPoint(x: 0.2, y: 0.3),
                startRadius: 0,
                endRadius: 500
            )
            .ignoresSafeArea()

            // circle at 80% 70%, rgba(30,50,90,0.2)
            RadialGradient(
                colors: [Color(red: 30/255, green: 50/255, blue: 90/255).opacity(0.2), .clear],
                center: UnitPoint(x: 0.8, y: 0.7),
                startRadius: 0,
                endRadius: 500
            )
            .ignoresSafeArea()

            // circle at 50% 50%, rgba(10,20,35,0.8) -> base
            RadialGradient(
                colors: [Color(red: 10/255, green: 20/255, blue: 35/255).opacity(0.8), base],
                center: .center,
                startRadius: 0,
                endRadius: 700
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - Radial Ticks
// 80 ticks around a 75pt base radius, driven by TimelineView for 60fps.

struct RadialTicks: View {
    var isRecording: Bool

    private let tickCount = 80
    private let baseRadius: CGFloat = 75

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            // HTML used Date.now() * 0.0015; we match by scaling to 1.5/sec.
            let time = ctx.date.timeIntervalSinceReferenceDate * 1.5
            Canvas { gctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<tickCount {
                    let angle = (Double(i) / Double(tickCount)) * 2 * .pi

                    let lineLength: Double
                    let alpha: Double
                    let color: Color

                    if isRecording {
                        let noise = sin(Double(i) * 0.4 + time * 6) * 12
                                  + cos(Double(i) * 0.2 - time * 4) * 8
                                  + Double.random(in: 0...1) * 6
                        lineLength = 6 + max(0, noise)
                        alpha = 0.5 + max(0, noise) / 20 * 0.5
                        color = Color.white.opacity(min(alpha, 1))
                    } else {
                        lineLength = 4 + sin(Double(i) * 0.15 + time) * 2
                        alpha = 0.2 + sin(Double(i) * 0.1 + time) * 0.1
                        color = Color(red: 200/255, green: 210/255, blue: 230/255)
                            .opacity(max(0, min(alpha, 1)))
                    }

                    // Draw from (0, -baseRadius) to (0, -baseRadius - lineLength)
                    // after translating to center and rotating by angle.
                    let start = CGPoint(x: 0, y: -baseRadius)
                    let end = CGPoint(x: 0, y: -baseRadius - CGFloat(lineLength))

                    let transform = CGAffineTransform.identity
                        .translatedBy(x: center.x, y: center.y)
                        .rotated(by: CGFloat(angle))

                    var path = Path()
                    path.move(to: start.applying(transform))
                    path.addLine(to: end.applying(transform))

                    gctx.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                }
            }
        }
    }
}

// MARK: - Glow Orb
// Soft blurred radial glow behind the mic button. Pulses when recording.

struct GlowOrb: View {
    var isRecording: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: isRecording
                        ? [Color(red: 1, green: 69/255, blue: 58/255).opacity(0.5), .clear]
                        : [Color(red: 60/255, green: 120/255, blue: 1).opacity(0.35), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 60
                )
            )
            .frame(width: 120, height: 120)
            .blur(radius: 24)
            .scaleEffect(isRecording ? (pulse ? 1.4 : 1.0) : 1.0)
            .opacity(isRecording ? (pulse ? 1.0 : 0.6) : 1.0)
            .onAppear {
                if isRecording { startPulse() }
            }
            .onChange(of: isRecording) { _, newValue in
                if newValue {
                    startPulse()
                } else {
                    pulse = false
                }
            }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Center Mic Button
// 100pt glass circle. Mic glyph when idle, red stop square when recording.

struct CenterMicButton: View {
    var isRecording: Bool
    var action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.03), Color.white.opacity(0.01)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .overlay(
                        // inset highlight
                        Circle()
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                            .padding(1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)

                if isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(red: 1, green: 69/255, blue: 58/255))
                        .frame(width: 24, height: 24)
                        .shadow(color: Color(red: 1, green: 69/255, blue: 58/255).opacity(0.7), radius: 10)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 100, height: 100)
            .scaleEffect(pressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isRecording)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
    }
}

// MARK: - HUD Wrapper
// Composes rings, ticks, glow, and the center button into a 320x320 stack.

struct HudWrapper: View {
    var isRecording: Bool
    var onTap: () -> Void

    @State private var dashRotation: Double = 0

    var body: some View {
        ZStack {
            // subtle ring (inset 15px -> 290x290)
            Circle()
                .stroke(Color.white.opacity(0.03), lineWidth: 1)
                .frame(width: 290, height: 290)

            // dashed ring (inset 40px -> 240x240)
            Circle()
                .stroke(
                    isRecording
                        ? Color(red: 1, green: 69/255, blue: 58/255).opacity(0.2)
                        : Color.white.opacity(0.1),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .frame(width: 240, height: 240)
                .rotationEffect(.degrees(isRecording ? dashRotation : 0))
                .onAppear {
                    if isRecording { startDashSpin() }
                }
                .onChange(of: isRecording) { _, newValue in
                    if newValue {
                        startDashSpin()
                    } else {
                        dashRotation = 0
                    }
                }

            // Radial ticks
            RadialTicks(isRecording: isRecording)
                .frame(width: 320, height: 320)

            // Glow
            GlowOrb(isRecording: isRecording)

            // Center mic button
            CenterMicButton(isRecording: isRecording, action: onTap)
        }
        .frame(width: 320, height: 320)
    }

    private func startDashSpin() {
        dashRotation = 0
        withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
            dashRotation = 360
        }
    }
}

// MARK: - Glass Nav Bar
// 4-button capsule at the bottom.

struct GlassNavBar: View {
    enum Item: Hashable { case home, guide, history, camera, profile }

    var highlighted: Item = .camera
    var onSelect: (Item) -> Void

    var body: some View {
        HStack {
            navButton(.home, icon: "house")
            Spacer()
            navButton(.guide, icon: "wrench.and.screwdriver")
            Spacer()
            navButton(.history, icon: "clock.arrow.circlepath")
            Spacer()
            navButton(.camera, icon: "camera")
            Spacer()
            navButton(.profile, icon: "person")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
    }

    @ViewBuilder
    private func navButton(_ item: Item, icon: String) -> some View {
        let isHighlighted = item == highlighted
        Button { onSelect(item) } label: {
            ZStack {
                if isHighlighted {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        .background(Circle().fill(Color.white.opacity(0.04)))
                        .frame(width: 44, height: 44)
                }
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(
                        isHighlighted
                            ? Color.white.opacity(0.8)
                            : Color.white.opacity(0.4)
                    )
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
