import Foundation
import SwiftUI
import Combine

enum OttoRoute: Hashable {
    case home
    case session
    case camera
    case history
    case profile
    case repairGuide
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
    // Injected from the root app so mode (local/remote) is shared globally.
    // Until attach(engine:) is called we keep a placeholder so the OttoStore
    // can be created before the view hierarchy injects the real one.
    private(set) var engine: InferenceController
    private var modelReady = false
    private var recognizerBag: [AnyCancellable] = []

    init(engine: InferenceController = InferenceController()) {
        self.engine = engine
        recognizer.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.partialTranscript = t }
            .store(in: &recognizerBag)
    }

    // Called from OttoRootView.task once the environment-injected controller
    // is in scope. Safe to call multiple times.
    func attach(engine: InferenceController) {
        self.engine = engine
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

    private func finishListeningAndRespond() async {
        let question = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        recognizer.stop()
        guard !question.isEmpty else { voice = .idle; return }
        history.append(Turn(role: .user, text: question))
        partialTranscript = ""
        voice = .thinking
        currentAnswer = ""

        if !modelReady { await warmUp() }

        await engine.generate(prompt: buildPromptFromHistory())
        let answer = engine.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        currentAnswer = answer
        history.append(Turn(role: .otto, text: answer))

        voice = .speaking
        speaker.speak(answer) { [weak self] in
            Task { @MainActor in self?.voice = .idle }
        }
    }

    private func buildPromptFromHistory() -> String {
        let recent = history.suffix(6).map { "\($0.role == .user ? "User" : "Otto"): \($0.text)" }
        return recent.joined(separator: "\n")
    }
}
