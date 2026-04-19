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
            imageProgress = 0

            // Show the text instructions immediately — don't block the UI
            // waiting for nanobanana. Images stream in below and update the
            // StepCard in place as each one lands.
            phase = .ready
            speakCurrentStep(includeTitle: true)

            // Save a text-only snapshot to history now so the entry exists
            // even if the user backs out before all images finish. It gets
            // overwritten with image paths once the background task completes.
            HistoryStore.shared.saveManual(draft)

            Task { [weak self] in
                await self?.streamImages(for: draft)
            }
        } catch {
            print("[Otto][Repair] generate failed: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    /// Generate all step images in parallel, publishing each one onto
    /// `manual` as it completes so the current StepCard re-renders in place.
    /// Failures on individual steps leave that step's placeholder in view
    /// rather than aborting the whole flow — text is already useful.
    private func streamImages(for draft: RepairManual) async {
        let svc = bananas
        await withTaskGroup(of: (Int, String?).self) { group in
            for (i, step) in draft.steps.enumerated() {
                group.addTask {
                    do {
                        let path = try await svc.generateImage(for: step, manual: draft)
                        return (i, path)
                    } catch {
                        print("[Otto][Banana] step \(i) failed: \(error.localizedDescription)")
                        return (i, nil)
                    }
                }
            }
            for await (i, path) in group {
                guard let path else { continue }
                guard var m = manual, m.steps.indices.contains(i) else { continue }
                m.steps[i].imagePNGPath = path
                manual = m
                imageProgress += 1
            }
        }

        if let final = manual {
            cache.save(final)
            HistoryStore.shared.saveManual(final)
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
