import Foundation
import SwiftUI
import Combine

// Facade exposed to the rest of the app. Holds both engines, routes every
// call to whichever backend matches the current `mode`, and re-publishes the
// active backend's state so SwiftUI views can observe a single @EnvironmentObject.
//
// Why not just inject the active engine directly? Because SwiftUI's
// @EnvironmentObject / @StateObject need a concrete type, and we want the
// mode toggle to swap backends at runtime without every view re-reading
// the environment. Going through one controller keeps the view tree stable.
@MainActor
final class InferenceController: ObservableObject {
    @Published var mode: AppMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: AppModeDefaults.storageKey)
            rebind()
            // Kick the newly-active backend so the UI sees a load state.
            Task { await self.loadIfNeeded() }
        }
    }

    let local: CactusEngine
    let remote: RemoteRelayEngine

    private var bag = Set<AnyCancellable>()

    // No default-arg initializers here — CactusEngine / RemoteRelayEngine are
    // @MainActor, and default values evaluate in the caller's isolation
    // context, which can be non-isolated. Building them inside the init body
    // runs under @MainActor and compiles cleanly.
    init() {
        self.local = CactusEngine()
        self.remote = RemoteRelayEngine()
        let stored = UserDefaults.standard.string(forKey: AppModeDefaults.storageKey)
        self.mode = stored.flatMap(AppMode.init(rawValue:)) ?? .local
        rebind()
    }

    // MARK: - Mirrored state (reads through to active backend)

    var loadState: CactusEngine.LoadState {
        mode == .local ? local.loadState : remote.loadState
    }
    var partial: String {
        mode == .local ? local.partial : remote.partial
    }
    var isGenerating: Bool {
        mode == .local ? local.isGenerating : remote.isGenerating
    }

    // MARK: - Public API (mirrors CactusEngine's surface)

    func loadIfNeeded() async {
        switch mode {
        case .local:  await local.loadIfNeeded()
        case .remote: await remote.loadIfNeeded()
        }
    }

    func generate(prompt: String) async {
        switch mode {
        case .local:  await local.generate(prompt: prompt)
        case .remote: await remote.generate(prompt: prompt)
        }
    }

    func generate(prompt: String, imagePath: String) async {
        switch mode {
        case .local:  await local.generate(prompt: prompt, imagePath: imagePath)
        case .remote: await remote.generate(prompt: prompt, imagePath: imagePath)
        }
    }

    func generate(pcmData: Data, imagePath: String? = nil) async {
        switch mode {
        case .local:  await local.generate(pcmData: pcmData, imagePath: imagePath)
        case .remote: await remote.generate(pcmData: pcmData, imagePath: imagePath)
        }
    }

    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int = 800) async throws -> String {
        switch mode {
        case .local:
            return try await local.complete(systemPrompt: systemPrompt,
                                            userPrompt: userPrompt,
                                            maxTokens: maxTokens)
        case .remote:
            return try await remote.complete(systemPrompt: systemPrompt,
                                             userPrompt: userPrompt,
                                             maxTokens: maxTokens)
        }
    }

    // MARK: - Plumbing

    // Forward objectWillChange from whichever backend is active. `partial`,
    // `loadState`, `isGenerating` are computed — they always read the
    // currently-active backend — so re-publishing objectWillChange is
    // enough to trigger SwiftUI view updates.
    private func rebind() {
        bag.removeAll()
        // objectWillChange is a concrete ObservableObjectPublisher on each
        // engine; `any ObservableObject` would erase it, so branch on mode.
        let publisher = (mode == .local)
            ? local.objectWillChange
            : remote.objectWillChange
        publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }
}
