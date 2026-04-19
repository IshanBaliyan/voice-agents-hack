import SwiftUI

// MARK: - Root

struct OttoRootView: View {
    @StateObject private var store = OttoStore()

    var body: some View {
        ZStack {
            OttoBackground()

            switch store.route {
            case .home:        VoiceHomeView().environmentObject(store)
            case .session:     ActiveSessionView().environmentObject(store)
            case .camera:      CameraScanView().environmentObject(store)
            case .history:     HistoryView().environmentObject(store)
            case .profile:     ProfileView().environmentObject(store)
            case .repairGuide: RepairGuideRootView().environmentObject(store)
            }
        }
        .preferredColorScheme(.dark)
        .task { await store.warmUp() }
    }
}

// MARK: - Home
// On first appear, the porsche drives up from the bottom of the screen on a
// perspective road and docks at its resting position. The road then fades
// away and the home UI (wordmark, orb, caption, camera) fades in around it.

struct VoiceHomeView: View {
    @EnvironmentObject var store: OttoStore

    @State private var arrived = false
    @State private var drive: CGFloat = 0        // 0 = far tiny at bottom, 1 = off the top
    @State private var roadPhase: CGFloat = 0
    @State private var introOpacity: Double = 1
    @State private var homeOpacity: Double = 0
    @State private var showHome = false

    private let carAspect: CGFloat = 752.0 / 1402.0

    private func dockedHeight(_ geo: GeometryProxy) -> CGFloat {
        min(geo.size.height * 0.26, 230)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                introLayer(geo: geo)
                    .opacity(introOpacity)
                    .allowsHitTesting(!showHome)

                if showHome {
                    homeLayer(geo: geo)
                        .opacity(homeOpacity)
                }
            }
        }
        .task {
            guard !arrived else { return }
            arrived = true
            // Match the reference: 0.5s per dash cycle (fast scroll).
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                roadPhase = 1
            }
            // Car drives the full length and exits off the top.
            withAnimation(.timingCurve(0.28, 0.0, 0.55, 1.0, duration: 3.4)) {
                drive = 1.0
            }
            try? await Task.sleep(nanoseconds: 3_500_000_000)

            // Car is gone. Swap to home page.
            showHome = true
            withAnimation(.easeInOut(duration: 0.55)) {
                introOpacity = 0
                homeOpacity = 1
            }
        }
    }

    // MARK: - Intro layer

    private func introLayer(geo: GeometryProxy) -> some View {
        let finalH = dockedHeight(geo) * 1.7
        let startH: CGFloat = 48
        let carH = startH + (finalH - startH) * drive
        let carW = carH * carAspect

        let startY = geo.size.height * 0.95
        let endY = -carH
        let carY = startY + (endY - startY) * drive

        return ZStack {
            AmbientBackground()
                .ignoresSafeArea()

            PerspectiveRoad(phase: roadPhase)
                .ignoresSafeArea()

            // 3. The car itself.
            Image("PorscheClipart")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: carW, height: carH)
                .shadow(color: OttoColor.orange.opacity(0.25 + 0.25 * Double(drive)),
                        radius: 26 + 22 * drive, x: 0, y: 10 + 14 * drive)
                .position(x: geo.size.width / 2, y: carY)

            // 4. Glassmorphic control panel — sits at the bottom like a HUD,
            // showing the driving caption while the car is on its way up.
            VStack {
                Spacer()
                GlassDrivingPanel(progress: drive)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
            }
        }
    }

    // MARK: - Home layer
    // Minimal landing: Otto wordmark, caption, porsche. Tap anywhere to open
    // the voice session (which owns the orb + camera button).

    private func homeLayer(geo: GeometryProxy) -> some View {
        let carH = min(geo.size.height * 0.42, 380)
        let carW = carH * carAspect

        return Button {
            store.go(.session)
        } label: {
            VStack(spacing: 0) {
                Spacer().frame(height: geo.size.height * 0.11)

                HStack(alignment: .top, spacing: 4) {
                    Text("Otto")
                        .font(OttoFont.serif(56, weight: .light))
                        .foregroundStyle(OttoColor.cream)
                    Circle().fill(OttoColor.orange)
                        .frame(width: 10, height: 10)
                        .offset(y: 24)
                }
                Label2Mono(text: "Your pocket mechanic")
                    .padding(.top, 4)

                Spacer()

                Image("PorscheClipart")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: carW, height: carH)
                    .shadow(color: OttoColor.orange.opacity(0.3), radius: 34, x: 0, y: 20)

                Spacer()

                Text("Tap anywhere to talk")
                    .font(OttoFont.mono(11, weight: .regular))
                    .tracking(2.4)
                    .foregroundStyle(OttoColor.creamFaint)
                    .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Session
// Live voice loop. Orb reflects true VoiceState; transcript shows what the
// recognizer heard or what Otto answered.

struct ActiveSessionView: View {
    @EnvironmentObject var store: OttoStore

    private var isRecording: Bool { store.voice == .listening }

    var body: some View {
        ZStack {
            AmbientBackground()
                .ignoresSafeArea()

            #if os(iOS) && !targetEnvironment(simulator)
            SessionCameraBackdrop()
                .ignoresSafeArea()
                .opacity(0.35)
            #endif

            LinearGradient(
                colors: [Color.black.opacity(0.55),
                         Color.clear,
                         Color.black.opacity(0.15),
                         Color.black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Otto wordmark top-left.
                HStack {
                    HStack(alignment: .top, spacing: 1) {
                        Text("Otto")
                            .font(OttoFont.serif(30, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Text(".")
                            .font(OttoFont.serif(26, weight: .semibold))
                            .foregroundStyle(OttoColor.orange)
                            .offset(y: 4)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 10)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                Spacer()

                // Live transcript / response text sits above the mic.
                transcriptBlock
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)

                // Compact HUD sitting just above the nav bar.
                HudWrapper(isRecording: isRecording) {
                    store.tapMic()
                }
                .scaleEffect(0.62)
                .frame(width: 320 * 0.62, height: 320 * 0.62)
                .padding(.bottom, 10)

                GlassNavBar(highlighted: .home) { handleNav($0) }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
    }

    // Text that sits above the mic. Shows live recognizer transcript while
    // listening, Otto's streaming answer while speaking, or a subtle
    // "Tap to talk" hint while idle.
    @ViewBuilder private var transcriptBlock: some View {
        Group {
            switch store.voice {
            case .listening:
                Text(store.partialTranscript.isEmpty ? "Listening…" : store.partialTranscript)
                    .font(OttoFont.serif(20, weight: .regular))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)

            case .thinking:
                Text("Thinking…")
                    .font(OttoFont.body(15, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.7))

            case .speaking:
                let a = store.currentAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(a.isEmpty ? "Speaking…" : a)
                    .font(OttoFont.serif(18, weight: .regular))
                    .italic()
                    .foregroundStyle(Color.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)

            case .idle:
                if let last = store.history.last, last.role == .otto {
                    Text(last.text)
                        .font(OttoFont.body(14))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                } else {
                    Text("Tap to talk")
                        .font(OttoFont.body(14, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .animation(.easeInOut(duration: 0.2), value: store.voice)
    }

    private func handleNav(_ item: GlassNavBar.Item) {
        switch item {
        case .home:    store.go(.session)   // "home" tab = voice recorder
        case .guide:   store.go(.repairGuide)
        case .history: store.go(.history)
        case .camera:  store.go(.camera)
        case .profile: store.go(.profile)
        }
    }
}

// MARK: - Shared nav routing
// Used by HistoryView / ProfileView so all tab-bearing pages share the same
// navigation logic. Home tab is the voice recorder (session).

func ottoNav(_ item: GlassNavBar.Item, store: OttoStore) {
    switch item {
    case .home:    store.go(.session)
    case .guide:   store.go(.repairGuide)
    case .history: store.go(.history)
    case .camera:  store.go(.camera)
    case .profile: store.go(.profile)
    }
}

// MARK: - History (mock)

struct HistoryView: View {
    @EnvironmentObject var store: OttoStore

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 0) {
                sessionHeader(title: "History",
                              subtitle: "YOUR PAST CONVERSATIONS")
                    .padding(.top, 40)

                Spacer()

                VStack(spacing: 14) {
                    ForEach(mockRows) { row in
                        MockHistoryRow(title: row.title, meta: row.meta)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                GlassNavBar(highlighted: .history) { ottoNav($0, store: store) }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
    }

    private struct HistoryRow: Identifiable {
        let id = UUID()
        let title: String
        let meta: String
    }

    private var mockRows: [HistoryRow] {
        [
            HistoryRow(title: "Changing a tire on my Civic", meta: "Today · 3 steps"),
            HistoryRow(title: "What engine is in this?",     meta: "Yesterday · 1 min"),
            HistoryRow(title: "Oil for a 2018 Honda",        meta: "Apr 14 · 2 min"),
        ]
    }
}

private struct MockHistoryRow: View {
    let title: String
    let meta: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.04))
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(OttoColor.orange.opacity(0.85))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(OttoFont.body(15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text(meta)
                    .font(OttoFont.mono(10))
                    .tracking(1.8)
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Profile (mock)

struct ProfileView: View {
    @EnvironmentObject var store: OttoStore

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 0) {
                sessionHeader(title: "Profile",
                              subtitle: "YOUR GARAGE")
                    .padding(.top, 40)

                Spacer()

                VStack(spacing: 18) {
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        Image(systemName: "person.fill")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                    .frame(width: 110, height: 110)

                    Text("You")
                        .font(OttoFont.serif(22, weight: .semibold))
                        .foregroundStyle(Color.white)

                    Text("2018 Honda Civic")
                        .font(OttoFont.mono(11))
                        .tracking(2.2)
                        .foregroundStyle(Color.white.opacity(0.45))

                    VStack(spacing: 10) {
                        MockProfileRow(icon: "car.fill",          label: "Vehicles")
                        MockProfileRow(icon: "wrench.and.screwdriver.fill", label: "Saved guides")
                        MockProfileRow(icon: "gearshape.fill",    label: "Settings")
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                }

                Spacer()

                GlassNavBar(highlighted: .profile) { ottoNav($0, store: store) }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
    }
}

private struct MockProfileRow: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(OttoColor.orange.opacity(0.85))
                .frame(width: 24)
            Text(label)
                .font(OttoFont.body(15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.88))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// Reusable header used by history/profile to match ActiveSessionView's look.
@ViewBuilder
private func sessionHeader(title: String, subtitle: String) -> some View {
    VStack(spacing: 8) {
        Text(title)
            .font(OttoFont.serif(42, weight: .semibold))
            .foregroundStyle(Color.white)
        Text(subtitle)
            .font(OttoFont.body(11, weight: .regular))
            .tracking(3.85)
            .foregroundStyle(Color.white.opacity(0.4))
    }
}

// MARK: - Camera

struct CameraScanView: View {
    @EnvironmentObject var store: OttoStore

    #if os(iOS) && !targetEnvironment(simulator)
    @StateObject private var camera = CameraController()
    #endif

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Background: live camera on device, styled placeholder on simulator
            // so we don't spin up AVCaptureSession (crashes / hangs in sim).
            cameraBackground

            // Top-left close — always hittable, not covered by camera layer.
            VStack {
                HStack {
                    Button {
                        store.go(.home)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 10)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                Spacer()

                // Shutter button — disabled on simulator.
                Button {
                    #if os(iOS) && !targetEnvironment(simulator)
                    Task { _ = await camera.capture() }
                    #endif
                } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 3).frame(width: 72, height: 72)
                        Circle().fill(Color.white.opacity(isSimulator ? 0.35 : 1.0))
                            .frame(width: 58, height: 58)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSimulator)
                .padding(.bottom, 34)
            }
        }
        #if os(iOS) && !targetEnvironment(simulator)
        .task {
            _ = await camera.requestAuthorization()
            camera.configureIfNeeded()
            camera.start()
        }
        .onDisappear { camera.stop() }
        #endif
    }

    @ViewBuilder
    private var cameraBackground: some View {
        #if os(iOS) && !targetEnvironment(simulator)
        if camera.isAuthorized {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
        } else {
            permissionPlaceholder
        }
        #else
        simulatorPlaceholder
        #endif
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("Camera access needed")
                .font(OttoFont.body(15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
            Text("Enable in Settings to scan tools & parts.")
                .font(OttoFont.body(13))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
    }

    private var simulatorPlaceholder: some View {
        ZStack {
            AmbientBackground()
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 50, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.5))
                Text("CAMERA UNAVAILABLE IN SIMULATOR")
                    .font(OttoFont.mono(11, weight: .medium))
                    .tracking(2.4)
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("Run on a real device to scan tools and parts.")
                    .font(OttoFont.body(13))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
        }
    }

}

#Preview { OttoRootView() }
