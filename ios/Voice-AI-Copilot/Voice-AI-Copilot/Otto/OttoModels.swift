import Foundation
import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

enum OttoRoute: Hashable {
    case home
    case session
    case camera
    case history
    case profile
    case repairGuide
    case training
    case exploded
}

enum VoiceState {
    case idle, listening, thinking, speaking
}

struct Turn: Identifiable, Hashable {
    let id = UUID()
    let role: Role
    var text: String
    enum Role { case user, otto }
}

@MainActor
final class OttoStore: ObservableObject {
    @Published var route: OttoRoute = .home
    @Published var voice: VoiceState = .idle
    @Published var partialTranscript: String = ""
    @Published var currentAnswer: String = ""
    @Published var history: [Turn] = []
    @Published var error: String?

    private let recognizer = SpeechRecognizer()
    private let speaker = Speaker()
    /// Streams raw int16 PCM from the Mac relay to the speaker as it arrives.
    /// Unused in local mode (CactusEngine has no audio side-channel).
    let pcmPlayer = PCM16StreamPlayer()
    /// Shared camera used by both the SessionCameraBackdrop preview and the
    /// still capture we trigger when the user releases the mic. Optional so
    /// non-iOS builds (and previews) still compile.
    #if os(iOS) && !targetEnvironment(simulator)
    let camera = CameraController()
    #endif
    // Injected from the root app so mode (local/remote) is shared globally.
    // Until attach(engine:) is called we keep a placeholder so the OttoStore
    // can be created before the view hierarchy injects the real one.
    private(set) var engine: InferenceController
    private var modelReady = false
    private var recognizerBag: [AnyCancellable] = []

    init() {
        // Placeholder controller — replaced when OttoRootView.task calls
        // attach(engine:) with the real environment-injected one. Default-arg
        // init() can't construct a @MainActor type from a non-isolated context.
        self.engine = InferenceController()
        recognizer.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.partialTranscript = t }
            .store(in: &recognizerBag)
    }

    // Called from OttoRootView.task once the environment-injected controller
    // is in scope. Safe to call multiple times.
    func attach(engine: InferenceController) {
        self.engine = engine
        // Route every streamed audio chunk from the Mac relay straight into
        // the player. Flip to .speaking on first chunk so the UI moves off
        // "Thinking…" the instant audio starts.
        engine.remote.onAudioChunk = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pcmPlayer.enqueue(data)
                if self.voice == .thinking { self.voice = .speaking }
            }
        }
    }

    func warmUp() async {
        await engine.loadIfNeeded()
        if case .ready = engine.loadState { modelReady = true }
    }

    func go(_ r: OttoRoute) { withAnimation(.easeInOut(duration: 0.28)) { route = r } }

    // MARK: - Voice loop

    func tapMic() {
        switch voice {
        case .idle:       Task { await beginListening() }
        case .listening:  Task { await finishListeningAndRespond() }
        case .thinking:   break
        case .speaking:   speaker.stop(); voice = .idle
        }
    }

    /// Clear the live voice session and return to a clean idle state. Used by
    /// the "Not now" chip in the speaking hand-off and anywhere else we want
    /// the user to start over from scratch. Does NOT touch persistent history
    /// (that's kept in HistoryStore) — only in-memory conversation context.
    func resetSession() {
        speaker.stop()
        pcmPlayer.stop()
        recognizer.stop()
        partialTranscript = ""
        currentAnswer = ""
        history.removeAll()
        error = nil
        voice = .idle
    }

    private func beginListening() async {
        let ok = await recognizer.requestAuthorization()
        guard ok else { error = "Microphone or speech permission denied."; return }
        do {
            try recognizer.start()
            voice = .listening
            if route == .home { go(.session) }
        } catch {
            self.error = "Couldn't start mic: \(error.localizedDescription)"
        }
    }

    // Hard wall-clock budget for the on-device (or relay) engine to produce
    // an answer before we give up and route the turn to Gemini cloud.
    // 4 seconds is aggressive — most E2B turns that were going to succeed
    // quickly have finished by then, and stuck prefills get cut short before
    // the user feels dead air.
    private static let engineTimeoutSeconds: Double = 4

    private func finishListeningAndRespond() async {
        let question = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        recognizer.stop()
        guard !question.isEmpty else { voice = .idle; return }
        history.append(Turn(role: .user, text: question))
        partialTranscript = ""
        voice = .thinking
        currentAnswer = ""

        if !modelReady { await warmUp() }

        // Grab a still from the live camera preview so the model can see
        // whatever the user was pointing the phone at when they stopped
        // speaking. Only wired on real iOS hardware — simulator and macOS
        // skip straight to the text-only path.
        let imagePath = await captureCurrentFrameIfAvailable()

        let prompt = buildPromptFromHistory()
        let answer = await answerWithTimeoutFallback(
            prompt: prompt, question: question, imagePath: imagePath
        )

        currentAnswer = answer
        history.append(Turn(role: .otto, text: answer))

        // Persist this Q&A turn so the History page can replay it later.
        HistoryStore.shared.saveQA(question: question, answer: answer)

        // Remote mode: Kokoro audio has already been streaming through
        // pcmPlayer; don't double-speak with AVSpeechSynthesizer. Wait for
        // the player's queue to drain before going back to idle so the UI
        // doesn't prematurely flip while audio is still coming out.
        if engine.mode == .remote {
            voice = .speaking
            let waitCapMs = 30_000
            var waitedMs = 0
            while (pcmPlayer.isPlaying || pcmPlayer.inFlight > 0) && waitedMs < waitCapMs {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitedMs += 100
            }
            voice = .idle
            return
        }

        voice = .speaking
        speaker.speak(answer) { [weak self] in
            Task { @MainActor in self?.voice = .idle }
        }
    }

    /// Snap a single frame from the shared Otto camera and write it to a
    /// temp JPEG, returning the path. Returns nil in the simulator, on
    /// non-iOS platforms, or when capture fails — callers treat nil as
    /// "text-only turn".
    private func captureCurrentFrameIfAvailable() async -> String? {
        #if os(iOS) && !targetEnvironment(simulator)
        guard let image = await camera.capture() else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.82) else { return nil }
        let path = NSTemporaryDirectory() + "otto-turn-\(UUID().uuidString).jpg"
        do {
            try jpeg.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // Race the engine against an 8-second timer. If the engine wins, use its
    // partial. If the timer wins, tell the engine to abandon what it's doing
    // and ask Gemini cloud for a free-form answer using the same prompt.
    //
    // We rely on engine.abandonCurrent() to stop the abandoned backend from
    // writing to `partial` after we've switched — but the underlying work
    // (cactusComplete, or the Mac relay turn) can't actually be cancelled,
    // so it runs to completion in the background and its tokens are dropped.
    private func answerWithTimeoutFallback(prompt: String, question: String, imagePath: String? = nil) async -> String {
        let localEngine = engine

        // Remote (Mac relay) mode: wait for the relay's answer. No Gemini
        // fallback — the whole point of remote mode is that the Mac is doing
        // the inference, so silently handing off to a third service would
        // mask relay issues and hide what the user actually selected.
        if engine.mode == .remote {
            if let imagePath {
                await localEngine.generate(prompt: prompt, imagePath: imagePath)
            } else {
                await localEngine.generate(prompt: prompt)
            }
            // RemoteRelayEngine.generate() returns once the WS frames are
            // sent; tokens stream back asynchronously. Wait for the relay
            // to finish (isGenerating flips false on end-of-turn text).
            let maxWaitMs = 60_000
            var waitedMs = 0
            while localEngine.isGenerating && waitedMs < maxWaitMs {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitedMs += 100
            }
            let text = localEngine.partial.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return "Sorry — the Mac relay didn't return an answer. Check that it's running."
            }
            return text
        }

        // Local (on-device) mode: race the engine against a short timer and
        // fall back to Gemini cloud if the phone is too slow or returns empty.
        enum RaceResult { case local(String); case timedOut }
        let timeout = Self.engineTimeoutSeconds

        let result: RaceResult = await withTaskGroup(of: RaceResult.self) { group in
            group.addTask { @MainActor in
                if let imagePath {
                    await localEngine.generate(prompt: prompt, imagePath: imagePath)
                } else {
                    await localEngine.generate(prompt: prompt)
                }
                return .local(localEngine.partial.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        switch result {
        case .local(let text) where !text.isEmpty:
            return text

        case .local:
            print("[Otto][Chat] on-device engine returned empty — asking Gemini cloud")
            return await cloudAnswer(for: question, imagePath: imagePath)

        case .timedOut:
            print("[Otto][Chat] on-device engine exceeded \(Int(timeout))s — abandoning, routing to Gemini cloud")
            engine.abandonCurrent()
            return await cloudAnswer(for: question, imagePath: imagePath)
        }
    }

    private let cloudChat = GeminiCloudChatService()

    private func cloudAnswer(for question: String, imagePath: String? = nil) async -> String {
        do {
            return try await cloudChat.answer(userPrompt: question, imagePath: imagePath)
        } catch {
            print("[Otto][Chat] cloud fallback also failed: \(error.localizedDescription)")
            return "Sorry — I'm having trouble reaching the answer right now. Could you try asking again?"
        }
    }

    private func buildPromptFromHistory() -> String {
        let recent = history.suffix(6).map { "\($0.role == .user ? "User" : "Otto"): \($0.text)" }
        return recent.joined(separator: "\n")
    }
}
