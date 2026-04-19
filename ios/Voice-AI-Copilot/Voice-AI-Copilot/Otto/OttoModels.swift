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

        let prompt = buildPromptFromHistory()
        let answer = await answerWithTimeoutFallback(prompt: prompt, question: question)

        currentAnswer = answer
        history.append(Turn(role: .otto, text: answer))

        voice = .speaking
        speaker.speak(answer) { [weak self] in
            Task { @MainActor in self?.voice = .idle }
        }
    }

    // Race the engine against an 8-second timer. If the engine wins, use its
    // partial. If the timer wins, tell the engine to abandon what it's doing
    // and ask Gemini cloud for a free-form answer using the same prompt.
    //
    // We rely on engine.abandonCurrent() to stop the abandoned backend from
    // writing to `partial` after we've switched — but the underlying work
    // (cactusComplete, or the Mac relay turn) can't actually be cancelled,
    // so it runs to completion in the background and its tokens are dropped.
    private func answerWithTimeoutFallback(prompt: String, question: String) async -> String {
        enum RaceResult { case local(String); case timedOut }

        let timeout = Self.engineTimeoutSeconds
        let localEngine = engine

        let result: RaceResult = await withTaskGroup(of: RaceResult.self) { group in
            group.addTask { @MainActor in
                await localEngine.generate(prompt: prompt)
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
            // Engine came back fast but empty. Fall through to cloud.
            print("[Otto][Chat] engine returned empty — asking Gemini cloud")
            return await cloudAnswer(for: question)

        case .timedOut:
            print("[Otto][Chat] engine exceeded \(Int(timeout))s — abandoning, routing to Gemini cloud")
            engine.abandonCurrent()
            return await cloudAnswer(for: question)
        }
    }

    private let cloudChat = GeminiCloudChatService()

    private func cloudAnswer(for question: String) async -> String {
        do {
            return try await cloudChat.answer(userPrompt: question)
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
