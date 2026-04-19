import Foundation
import SwiftUI
import Combine

// Thread-safe token accumulator: cactusComplete's token callback fires on a
// background worker thread; the awaiting Task reads the final buffer after
// cactus_complete returns synchronously.
nonisolated final class TokenBuffer: @unchecked Sendable {
    private var s = ""
    private let lock = NSLock()
    func append(_ t: String) { lock.lock(); s.append(t); lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return s }
}

@MainActor
final class CactusEngine: ObservableObject {
    enum LoadState { case idle, loading, ready, failed(String) }

    @Published var loadState: LoadState = .idle
    @Published var partial: String = ""
    @Published var isGenerating: Bool = false

    private var model: CactusModelT?

    func loadIfNeeded() async {
        if case .ready = loadState { return }
        if case .loading = loadState { return }
        loadState = .loading

        // Dev-mode: point directly at E2B weights on the Mac filesystem (works in Simulator only).
        // For a real device build, we'd download these to FileManager.cachesDirectory at first launch.
        let devPath = "/Users/ishan/Development/yc-voice-april-2026/yc-voice-v2/cactus/weights/gemma-4-e2b-it"
        let bundlePath = Bundle.main.resourcePath ?? ""

        let path: String
        if FileManager.default.fileExists(atPath: devPath + "/config.txt") {
            path = devPath
        } else if FileManager.default.fileExists(atPath: bundlePath + "/config.txt") {
            path = bundlePath
        } else {
            loadState = .failed("Model weights not found. Expected at \(devPath) (Simulator dev path) or bundle root.")
            return
        }
        do {
            let handle = try await Task.detached(priority: .userInitiated) {
                try cactusInit(path, nil, false)
            }.value
            self.model = handle
            self.loadState = .ready
        } catch {
            self.loadState = .failed("cactusInit failed: \(error.localizedDescription)")
        }
    }

    func generate(prompt: String) async {
        guard let model else { return }
        isGenerating = true
        partial = ""

        let messagesJson = buildMessagesJson(userPrompt: prompt)
        let options = #"{"max_tokens":200,"temperature":0.2,"top_p":0.9,"stop":["<end_of_turn>","<|end|>","</s>"]}"#

        do {
            try await Task.detached(priority: .userInitiated) { [weak self] in
                _ = try cactusComplete(model, messagesJson, options, nil) { token, _ in
                    Task { @MainActor in
                        self?.partial.append(token)
                    }
                }
            }.value
        } catch {
            partial.append("\n\n[error] \(error.localizedDescription)")
        }

        isGenerating = false
    }

    deinit {
        if let model { cactusDestroy(model) }
    }

    // One-shot completion for structured output. Does NOT mutate `partial` /
    // `isGenerating` — lets the repair-guide path run without interfering with
    // the voice assistant's streaming UI.
    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int = 800) async throws -> String {
        // Kick off load if this is the very first call.
        if case .idle = loadState { await loadIfNeeded() }

        // If warmUp from OttoStore is mid-flight, loadIfNeeded above returned
        // immediately — poll until .ready or .failed. 60s cap.
        var waitedMs = 0
        while case .loading = loadState {
            if waitedMs >= 60_000 {
                throw NSError(domain: "Otto.Cactus", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "model still loading after 60s"])
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            waitedMs += 150
        }
        if case let .failed(msg) = loadState {
            throw NSError(domain: "Otto.Cactus", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "model load failed: \(msg)"])
        }
        guard let model else {
            throw NSError(domain: "Otto.Cactus", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "model not loaded"])
        }
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": userPrompt]
        ]
        let messagesJson = String(
            data: try JSONSerialization.data(withJSONObject: messages),
            encoding: .utf8
        )!
        let options = "{\"max_tokens\":\(maxTokens),\"temperature\":0.2,\"top_p\":0.9,\"stop\":[\"<end_of_turn>\",\"<|end|>\",\"</s>\"]}"

        let buffer = TokenBuffer()
        try await Task.detached(priority: .userInitiated) {
            _ = try cactusComplete(model, messagesJson, options, nil) { token, _ in
                buffer.append(token)
            }
        }.value
        return buffer.snapshot()
    }

    private func buildMessagesJson(userPrompt: String) -> String {
        let obj: [[String: String]] = [
            ["role": "system", "content": "You are a concise, helpful assistant. Answer briefly in plain English."],
            ["role": "user", "content": userPrompt]
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }
}
