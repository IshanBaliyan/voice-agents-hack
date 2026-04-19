import Foundation
import SwiftUI
import Combine

// MARK: - Wire format

struct RepairStep: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var description: String
    var tools: [String]
    var imagePNGPath: String?

    enum CodingKeys: String, CodingKey { case id, title, description, tools, imagePNGPath }
}

struct RepairManual: Codable, Hashable {
    let query: String
    let title: String
    let vehicle: String
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
    private let gemma: GemmaInstructionService
    private let bananas = NanobananaService()
    private let cache = RepairGuideCache()
    private let engine: CactusEngine
    private var listeningMode: ListeningMode = .query
    private var bag: [AnyCancellable] = []

    private enum ListeningMode { case query, command }

    init(engine: CactusEngine) {
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
            phase = .ready
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
                let path = try await bananas.generateImage(for: step,
                                                           manualTitle: draft.title,
                                                           vehicle: vehicle)
                withImages.steps[i].imagePNGPath = path
                manual = withImages
                imageProgress = i + 1
            }

            cache.save(withImages)
            phase = .ready
        } catch {
            print("[Otto][Repair] generate failed: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Step navigation

    func nextStep() {
        guard let m = manual else { return }
        currentStep = min(currentStep + 1, max(0, m.steps.count - 1))
    }

    func prevStep() {
        currentStep = max(currentStep - 1, 0)
    }

    /// Short-window listener that advances on "next" / "back".
    func beginStepListening() {
        guard phase == .ready else { return }
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
        phase = .idle
        transcript = ""
        manual = nil
        currentStep = 0
        imageProgress = 0
        commandHeard = ""
    }
}
