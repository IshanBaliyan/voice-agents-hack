import SwiftUI
import Combine

// MARK: - Root
//
// Bridges the SwiftUI environment CactusEngine (loaded once at app launch) to
// the OttoStore. We defer the store's creation until onAppear because
// @EnvironmentObject isn't safe to read from a property initializer.

struct OttoRootView: View {
    @EnvironmentObject private var engine: CactusEngine
    @StateObject private var storeHost = OttoStoreHost()
    @State private var showSplash = true

    var body: some View {
        ZStack {
            OttoBackground()

            if let store = storeHost.store {
                OttoRouterView(store: store, engine: engine)
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
        .task {
            storeHost.bind(engine: engine)
            await storeHost.store?.warmUp()
        }
    }
}

/// Observes the OttoStore so SwiftUI re-evaluates the body when `route` or
/// `showTraining` changes. Splitting this out of `OttoRootView` lets us keep
/// the store owned by a host (bound to the env engine at task-time) while
/// still getting the subscription semantics of @ObservedObject.
private struct OttoRouterView: View {
    @ObservedObject var store: OttoStore
    let engine: CactusEngine

    var body: some View {
        Group {
            switch store.route {
            case .home:    VoiceHomeView().environmentObject(store)
            case .session: ActiveSessionView().environmentObject(store)
            case .camera:  CameraScanView().environmentObject(store)
            }
        }
        .sheet(isPresented: $store.showTraining) {
            CoursePickerView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

/// Holds the single OttoStore instance once the engine is available. Keeping
/// this out of OttoRootView lets us use @StateObject (which must own its
/// wrapped value) while still binding the store to an env-provided engine.
@MainActor
final class OttoStoreHost: ObservableObject {
    @Published private(set) var store: OttoStore?
    func bind(engine: CactusEngine) {
        if store == nil { store = OttoStore(engine: engine) }
    }
}

// MARK: - Home

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

            if let error = store.error {
                Text(error)
                    .font(OttoFont.body(12))
                    .foregroundStyle(OttoColor.danger)
                    .padding(.top, 8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            HStack(spacing: 18) {
                FloatingIconButton(systemName: "camera") { store.go(.camera) }
                FloatingIconButton(systemName: "wrench.and.screwdriver") { store.openTraining() }
            }
            .padding(.bottom, 34)
        }
    }
}

// MARK: - Active session

struct ActiveSessionView: View {
    @EnvironmentObject var store: OttoStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                FloatingIconButton(systemName: "xmark") { store.go(.home) }
                Spacer()
                if store.hasPendingImage {
                    PhotoReadyBadge()
                        .padding(.trailing, 8)
                }
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

    // The server owns STT, so the live transcript is never available on-device.
    // During .listening we just show a shimmering hint; during .thinking /
    // .speaking we show the streamed answer; at rest we show the last answer.
    @ViewBuilder private var transcriptArea: some View {
        switch store.voice {
        case .listening:
            Text("Listening…")
                .font(OttoFont.body(16))
                .foregroundStyle(OttoColor.creamFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 60)
        case .thinking, .speaking:
            if !store.currentAnswer.isEmpty {
                Text("\u{201C}\(store.currentAnswer)\u{201D}")
                    .font(OttoFont.serif(18))
                    .italic()
                    .foregroundStyle(OttoColor.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
            } else {
                Color.clear.frame(height: 60)
            }
        case .idle:
            if !store.currentAnswer.isEmpty {
                Text(store.currentAnswer)
                    .font(OttoFont.body(15))
                    .foregroundStyle(OttoColor.creamDim)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
            } else if let error = store.error {
                Text(error)
                    .font(OttoFont.body(13))
                    .foregroundStyle(OttoColor.danger)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
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
        case .idle:      return store.hasPendingImage ? "Tap the orb and ask about the photo" : "Tap the orb to ask another question"
        case .listening: return "Tap when you're done"
        case .thinking:  return " "
        case .speaking:  return "Tap to interrupt"
        }
    }
}

private struct PhotoReadyBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.fill")
                .font(.system(size: 11, weight: .bold))
            Text("PHOTO READY")
                .font(OttoFont.mono(10, weight: .semibold))
                .tracking(1.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(OttoColor.navyDeep)
        .background(OttoColor.orange)
        .clipShape(Capsule())
    }
}

// MARK: - Camera

struct CameraScanView: View {
    @EnvironmentObject var store: OttoStore
    @State private var errorText: String?
    @State private var isCapturing = false
    @State private var previewReady = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if previewReady {
                CameraPreviewView(session: store.camera.session)
                    .ignoresSafeArea()
            } else if errorText != nil {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(OttoColor.creamDim)
                    Text("Camera unavailable")
                        .font(OttoFont.body(15))
                        .foregroundStyle(OttoColor.cream)
                }
            }

            VStack {
                HStack {
                    FloatingIconButton(systemName: "xmark") {
                        store.camera.stop()
                        store.go(.session)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                Spacer()

                if let errorText {
                    Text(errorText)
                        .font(OttoFont.body(13))
                        .foregroundStyle(OttoColor.danger)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(OttoColor.navyDeep.opacity(0.7))
                        .clipShape(Capsule())
                        .padding(.bottom, 10)
                }

                Button(action: snap) {
                    ZStack {
                        Circle().stroke(OttoColor.cream, lineWidth: 3).frame(width: 72, height: 72)
                        Circle().fill(OttoColor.cream).frame(width: 58, height: 58)
                        if isCapturing {
                            ProgressView()
                                .tint(OttoColor.navyDeep)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isCapturing)
                .padding(.bottom, 34)
            }
        }
        .task {
            do {
                try await store.camera.start()
                previewReady = true
            } catch {
                previewReady = false
                errorText = error.localizedDescription
            }
        }
        .onDisappear { store.camera.stop() }
    }

    private func snap() {
        guard !isCapturing else { return }
        isCapturing = true
        errorText = nil
        Task {
            let url = await store.camera.capture()
            isCapturing = false
            guard let url else {
                errorText = "Couldn't capture a frame."
                return
            }
            store.cameraCaptured(jpegPath: url.path)
        }
    }
}

#Preview {
    OttoRootView()
        .environmentObject(CactusEngine())
}
