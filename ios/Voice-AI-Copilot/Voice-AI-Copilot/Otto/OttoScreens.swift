import SwiftUI

// MARK: - Root

struct OttoRootView: View {
    @StateObject private var store = OttoStore()
    @State private var showSplash = true

    var body: some View {
        ZStack {
            OttoBackground()

            switch store.route {
            case .home:    VoiceHomeView().environmentObject(store)
            case .session: ActiveSessionView().environmentObject(store)
            case .camera:  CameraScanView().environmentObject(store)
            }

            if showSplash {
                OttoSplashView {
                    withAnimation(.easeInOut(duration: 0.4)) { showSplash = false }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .task { await store.warmUp() }
    }
}

// MARK: - Home
// Minimal idle state. One action: tap the orb to start talking.

struct VoiceHomeView: View {
    @EnvironmentObject var store: OttoStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)

            HStack(alignment: .top, spacing: 4) {
                Text("Otto")
                    .font(OttoFont.serif(48, weight: .light))
                    .foregroundStyle(OttoColor.cream)
                Circle().fill(OttoColor.orange)
                    .frame(width: 9, height: 9)
                    .offset(y: 20)
            }
            Label2Mono(text: "Your pocket mechanic")
                .padding(.top, 4)

            Spacer()

            Button { store.tapMic() } label: {
                BreathingOrb(state: .idle, size: 170)
            }
            .buttonStyle(.plain)

            Text("Tap to talk")
                .font(OttoFont.body(14, weight: .medium))
                .foregroundStyle(OttoColor.cream)
                .padding(.top, 24)

            Spacer()

            HStack {
                FloatingIconButton(systemName: "camera") { store.go(.camera) }
            }
            .padding(.bottom, 34)
        }
    }
}

// MARK: - Active Session
// Live voice loop. Orb reflects true VoiceState; transcript shows what the
// recognizer heard or what Otto answered.

struct ActiveSessionView: View {
    @EnvironmentObject var store: OttoStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                FloatingIconButton(systemName: "xmark") { store.go(.home) }
                Spacer()
                FloatingIconButton(systemName: "camera") { store.go(.camera) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer()

            Button { store.tapMic() } label: {
                BreathingOrb(state: store.voice, size: 170)
            }
            .buttonStyle(.plain)

            Label2Mono(text: stateLabel)
                .padding(.top, 22)

            Spacer()

            transcriptArea
                .padding(.horizontal, 22)
                .padding(.bottom, 30)

            Text(promptHint)
                .font(OttoFont.body(13))
                .foregroundStyle(OttoColor.creamFaint)
                .padding(.bottom, 26)
        }
    }

    @ViewBuilder private var transcriptArea: some View {
        switch store.voice {
        case .listening:
            Text(store.partialTranscript.isEmpty ? "Listening…" : store.partialTranscript)
                .font(OttoFont.body(16))
                .foregroundStyle(store.partialTranscript.isEmpty ? OttoColor.creamFaint : OttoColor.cream)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 60)
        case .thinking, .speaking:
            if !store.currentAnswer.isEmpty {
                Text("\u{201C}\(store.currentAnswer)\u{201D}")
                    .font(OttoFont.serif(18))
                    .italic()
                    .foregroundStyle(OttoColor.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
            } else {
                Color.clear.frame(height: 60)
            }
        case .idle:
            if let last = store.history.last, last.role == .otto {
                Text(last.text)
                    .font(OttoFont.body(15))
                    .foregroundStyle(OttoColor.creamDim)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            } else {
                Color.clear.frame(height: 60)
            }
        }
    }

    private var stateLabel: String {
        switch store.voice {
        case .idle:      return "Tap to speak"
        case .listening: return "Listening"
        case .thinking:  return "Thinking"
        case .speaking:  return "Speaking"
        }
    }

    private var promptHint: String {
        switch store.voice {
        case .idle:      return "Tap the orb to ask another question"
        case .listening: return "Tap when you're done"
        case .thinking:  return " "
        case .speaking:  return "Tap to interrupt"
        }
    }
}

// MARK: - Camera

struct CameraScanView: View {
    @EnvironmentObject var store: OttoStore

    #if os(iOS)
    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(OttoColor.creamDim)
                    Text("Camera access needed")
                        .font(OttoFont.body(15))
                        .foregroundStyle(OttoColor.cream)
                }
            }

            VStack {
                HStack {
                    FloatingIconButton(systemName: "xmark") { store.go(.session) }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                Spacer()

                Button {
                    Task { _ = await camera.capture() }
                } label: {
                    ZStack {
                        Circle().stroke(OttoColor.cream, lineWidth: 3).frame(width: 72, height: 72)
                        Circle().fill(OttoColor.cream).frame(width: 58, height: 58)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 34)
            }
        }
        .task {
            _ = await camera.requestAuthorization()
            camera.configureIfNeeded()
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
    #else
    var body: some View {
        Text("Camera is iOS only")
            .foregroundStyle(OttoColor.cream)
    }
    #endif
}

#Preview { OttoRootView() }
