import Foundation
import SwiftUI
import Combine

// MARK: - Wire format
//
// Structure adapted from Neel49/nano_banana: a locked "scene bible" plus per-
// step state/action/camera fields lets the image model maintain visual
// continuity across steps while varying framing — wide establishing shots for
// "locate the part", close-ups with surrounding context for "operate here".

struct SceneBible: Codable, Hashable {
    let vehicle: String        // e.g. "2018 Honda Civic, Sonic Gray Pearl, stock 16-inch alloy wheels"
    let environment: String    // e.g. "residential concrete driveway, bright morning light"
    let style: String          // our blueprint style descriptor (locked)
}

struct RepairStep: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var description: String      // 2–4 sentences now (on-screen instruction)
    var tools: [String]          // materials for THIS step
    var safetyNote: String?      // optional one-line caution

    // Image-generation hints (rich path). Any can be nil — we fall back to a
    // simple style prompt built from description if absent.
    var stateBullets: [String]?  // "must be visibly true in frame" bullets
    var action: String?          // what the focal hand / tool is doing right now
    var camera: String?          // framing: "extreme close-up of the oil drain plug on the underside of the oil pan, with the front subframe visible for location reference"

    var imagePNGPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, tools, safetyNote
        case stateBullets, action, camera, imagePNGPath
    }
}

struct RepairManual: Codable, Hashable {
    let query: String
    let title: String
    let vehicle: String
    var overview: String?
    var requiredTools: [String]
    var safetyWarnings: [String]
    var sceneBible: SceneBible?
    var steps: [RepairStep]
}

enum RepairPhase: Equatable {
    case idle
    case listening
    case thinking            // Gemma generating JSON
    case generatingImages    // Nanobanana generating PNGs
    case ready
    case error(String)
}

// MARK: - Store

@MainActor
final class RepairGuideStore: ObservableObject {
    @Published var phase: RepairPhase = .idle
    @Published var transcript: String = ""
    @Published var manual: RepairManual?
    @Published var currentStep: Int = 0
    @Published var imageProgress: Int = 0
    @Published var commandHeard: String = ""   // short "say NEXT" listener

    let vehicle: String = "2018 Honda Civic"

    private let recognizer = SpeechRecognizer()
    private let speaker = Speaker()
    private let gemma: GemmaInstructionService
    private let bananas = NanobananaService()
    private let cache = RepairGuideCache()
    private let engine: InferenceController
    private var listeningMode: ListeningMode = .query
    private var bag: [AnyCancellable] = []

    private enum ListeningMode { case query, command }

    init(engine: InferenceController) {
        self.engine = engine
        self.gemma = GemmaInstructionService(engine: engine)
        recognizer.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self else { return }
                switch self.listeningMode {
                case .query:   self.transcript = t
                case .command: self.commandHeard = t
                }
            }
            .store(in: &bag)
    }

    // MARK: - Intro / query flow

    func tapMic() {
        switch phase {
        case .idle, .error: Task { await beginListening() }
        case .listening:    Task { await finishListeningAndGenerate() }
        default: break
        }
    }

    private func beginListening() async {
        let ok = await recognizer.requestAuthorization()
        guard ok else {
            phase = .error("Microphone permission denied.")
            return
        }
        do {
            listeningMode = .query
            transcript = ""
            try recognizer.start()
            phase = .listening
        } catch {
            phase = .error("Couldn't start mic: \(error.localizedDescription)")
        }
    }

    private func finishListeningAndGenerate() async {
        let q = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        recognizer.stop()
        guard !q.isEmpty else { phase = .idle; return }
        await generate(for: q)
    }

    func generate(for query: String) async {
        phase = .thinking
        transcript = query

        if let cached = cache.load(for: query) {
            manual = cached
            currentStep = 0
            // Bump the history row to "now" — user re-opened this manual.
            HistoryStore.shared.saveManual(cached)
            phase = .ready
            speakCurrentStep(includeTitle: true)
            return
        }

        do {
            let draft = try await gemma.generateManual(for: query, vehicle: vehicle)
            manual = draft
            currentStep = 0

            phase = .generatingImages
            imageProgress = 0
            var withImages = draft
            for (i, step) in draft.steps.enumerated() {
                let path = try await bananas.generateImage(for: step, manual: withImages)
                withImages.steps[i].imagePNGPath = path
                manual = withImages
                imageProgress = i + 1
            }

            cache.save(withImages)
            // Save to history so the user can come back to this manual later.
            // Saved AFTER images finish so the thumbnail path resolves.
            HistoryStore.shared.saveManual(withImages)
            phase = .ready
            speakCurrentStep(includeTitle: true)
        } catch {
            print("[Otto][Repair] generate failed: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Step navigation

    func nextStep() {
        guard let m = manual else { return }
        let target = min(currentStep + 1, max(0, m.steps.count - 1))
        guard target != currentStep else { return }
        currentStep = target
        speakCurrentStep()
    }

    func prevStep() {
        let target = max(currentStep - 1, 0)
        guard target != currentStep else { return }
        currentStep = target
        speakCurrentStep()
    }

    /// Read the current step aloud. Title + description — keeps it short
    /// enough to be skimmable but long enough that the user can work hands-
    /// free without looking at the screen.
    func speakCurrentStep(includeTitle: Bool = true) {
        guard let m = manual, m.steps.indices.contains(currentStep) else { return }
        let step = m.steps[currentStep]
        let stepNumber = currentStep + 1
        var parts: [String] = []
        if includeTitle, currentStep == 0 {
            parts.append(m.title + ".")
        }
        parts.append("Step \(stepNumber). \(step.title).")
        parts.append(step.description)
        if let safety = step.safetyNote, !safety.isEmpty {
            parts.append("Safety note: \(safety)")
        }
        if !step.tools.isEmpty {
            parts.append("You'll need: \(step.tools.joined(separator: ", ")).")
        }
        let utterance = parts.joined(separator: " ")
        speaker.stop()  // cut off any in-flight playback before starting fresh
        speaker.speak(utterance)
    }

    func toggleSpeech() {
        if speaker.isSpeaking {
            speaker.stop()
        } else {
            speakCurrentStep(includeTitle: false)
        }
    }

    /// Short-window listener that advances on "next" / "back".
    func beginStepListening() {
        guard phase == .ready else { return }
        // Kill TTS before arming the mic — otherwise the speaker bleeds into
        // the recognizer and we hear our own prompt as user input.
        speaker.stop()
        listeningMode = .command
        commandHeard = ""
        do { try recognizer.start() } catch { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self else { return }
            self.recognizer.stop()
            let heard = self.commandHeard.lowercased()
            if heard.contains("next")      { self.nextStep() }
            else if heard.contains("back") || heard.contains("previous") { self.prevStep() }
        }
    }

    func reset() {
        recognizer.stop()
        speaker.stop()
        phase = .idle
        transcript = ""
        manual = nil
        currentStep = 0
        imageProgress = 0
        commandHeard = ""
    }
}
