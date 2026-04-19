import Foundation
import SwiftUI
import Combine

enum OttoRoute: Hashable {
    case home
    case session
    case camera
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
    private let engine = CactusEngine()
    private var modelReady = false
    private var recognizerBag: [AnyCancellable] = []

    init() {
        recognizer.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.partialTranscript = t }
            .store(in: &recognizerBag)
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
