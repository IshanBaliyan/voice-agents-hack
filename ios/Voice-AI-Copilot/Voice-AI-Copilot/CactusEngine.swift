import Foundation
import SwiftUI
import Combine

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

        guard let resourcePath = Bundle.main.resourcePath,
              FileManager.default.fileExists(atPath: resourcePath + "/config.txt") else {
            loadState = .failed("Model weights not found in app bundle (expected config.txt + layer_*.weights at bundle root).")
            return
        }

        let path = resourcePath
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
        let options = #"{"max_tokens":256,"temperature":0.7}"#

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

    private func buildMessagesJson(userPrompt: String) -> String {
        let obj: [[String: String]] = [["role": "user", "content": userPrompt]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }
}
