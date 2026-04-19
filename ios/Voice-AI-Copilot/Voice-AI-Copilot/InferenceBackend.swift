import Foundation

// Public surface that both CactusEngine (local) and RemoteRelayEngine
// (Mac-server relay) expose. The @MainActor'd ObservableObject conformance
// is declared on each concrete type — protocols can't require it here
// without dragging in associated types.
@MainActor
protocol InferenceBackend: AnyObject {
    var loadState: CactusEngine.LoadState { get }
    var partial: String { get }
    var isGenerating: Bool { get }

    func loadIfNeeded() async

    func generate(prompt: String) async
    func generate(prompt: String, imagePath: String) async
    func generate(pcmData: Data, imagePath: String?) async

    // One-shot structured completion used by GemmaInstructionService.
    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String
}
