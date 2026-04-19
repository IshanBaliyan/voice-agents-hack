import Foundation
import SwiftUI
import Combine

// MARK: - Routes & state

enum OttoRoute: Hashable {
    case home
    case session
    case camera
}

enum VoiceState {
    case idle, listening, thinking, speaking
}

// MARK: - Store
//
// OttoStore is the glue between the Otto UI and our server-backed pipeline.
// The original design used on-device SFSpeechRecognizer + AVSpeechSynthesizer;
// here the Mac-side cactus_server handles both STT and TTS, so the store drives
// `CactusEngine` (WebSocket) + `AudioRecorder` (16 kHz PCM mic) + `CameraCapture`
// (JPEG) directly and derives `voice` from their published flags.
//
// The engine is injected so the same instance backs the Training tab sheet —
// loading Gemma twice would OOM the phone.

@MainActor
final class OttoStore: ObservableObject {
    @Published var route: OttoRoute = .home
    @Published var showTraining: Bool = false
    @Published var voice: VoiceState = .idle
    @Published var currentAnswer: String = ""
    @Published var error: String?

    let engine: CactusEngine
    let recorder = AudioRecorder()
    let camera = CameraCapture()

    /// Image captured in the camera scan view. Consumed on the next mic turn
    /// so a photo + question get sent to the server as a single image+audio
    /// pair, which is how the server's prefill expects multimodal input.
    private var pendingImagePath: String?

    private var bag: Set<AnyCancellable> = []

    init(engine: CactusEngine) {
        self.engine = engine

        // Mirror engine + recorder flags into a single VoiceState so the orb
        // doesn't have to juggle three booleans. Priority: speaking > thinking
        // > listening > idle — i.e. the most "active" state wins, matching the
        // underlying lifecycle (mic ends before the server starts generating,
        // which ends before audio starts playing).
        Publishers.CombineLatest4(
            recorder.$isRecording,
            engine.$isGenerating,
            engine.$isPlayingAudio,
            engine.$partial
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] recording, generating, playing, partial in
            guard let self else { return }
            self.currentAnswer = partial
            let next: VoiceState = {
                if playing { return .speaking }
                if generating { return .thinking }
                if recording { return .listening }
                return .idle
            }()
            if self.voice != next {
                withAnimation(.easeInOut(duration: 0.25)) { self.voice = next }
            }
        }
        .store(in: &bag)
    }

    func warmUp() async {
        await engine.loadIfNeeded()
    }

    func go(_ r: OttoRoute) {
        withAnimation(.easeInOut(duration: 0.28)) { route = r }
    }

    // MARK: - Mic loop

    func tapMic() {
        switch voice {
        case .idle:      Task { await beginListening() }
        case .listening: Task { await finishListeningAndSend() }
        case .thinking:  break // server in flight — let it finish
        case .speaking:  engine.interruptAudio()
        }
    }

    private func beginListening() async {
        error = nil
        do {
            try await recorder.start()
            if route == .home { go(.session) }
        } catch {
            self.error = "Couldn't start mic: \(error.localizedDescription)"
        }
    }

    private func finishListeningAndSend() async {
        let pcm = recorder.stop()
        guard !pcm.isEmpty else {
            error = "No audio captured."
            return
        }
        let imagePath = pendingImagePath
        pendingImagePath = nil

        await engine.generate(pcmData: pcm, imagePath: imagePath)

        // Clean up the temp JPEG after the server has consumed it.
        if let imagePath {
            try? FileManager.default.removeItem(atPath: imagePath)
        }
    }

    // MARK: - Camera

    func cameraCaptured(jpegPath: String) {
        if let old = pendingImagePath {
            try? FileManager.default.removeItem(atPath: old)
        }
        pendingImagePath = jpegPath
        go(.session)
    }

    func discardCameraCapture() {
        if let path = pendingImagePath {
            try? FileManager.default.removeItem(atPath: path)
            pendingImagePath = nil
        }
    }

    var hasPendingImage: Bool { pendingImagePath != nil }

    // MARK: - Training

    func openTraining() {
        // The mic must be idle when the training sheet appears — its
        // `TrainingSessionView` wants the same engine for its coach prompts.
        if recorder.isRecording { _ = recorder.stop() }
        showTraining = true
    }
}
