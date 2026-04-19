import Foundation
import Combine
import os

// WebSocket-backed inference engine. Mirrors CactusEngine's public API so it
// can be swapped in wherever CactusEngine is used today. Protocol stolen from
// changmin-test-ios-app/iphone-test/WebSocketManager.swift:
//
//   C→S: {"type":"audio", "data":<base64 PCM chunk>}
//        {"type":"image", "data":<base64 JPEG>}
//        {"type":"text",  "data":<utf8 text>}
//        {"type":"system","data":""}              // end-of-turn marker
//   S→C: {"type":"status","status":"loading|connected|error"}
//        {"type":"token", "data":<base64 text>}   // streaming deltas
//        {"type":"audio", "data":<base64 audio>}  // streaming TTS chunks
//        {"type":"text",  "data":<base64 fullText>} // end-of-turn final text
//        {"type":"page_image", ...}               // (RAG hits, ignored here)
//
// The streaming model matches CactusEngine: incoming tokens get appended to
// `partial`, and `isGenerating` stays true until the end-of-turn `text` blob
// arrives or the socket errors.
@MainActor
final class RemoteRelayEngine: ObservableObject {
    @Published var loadState: CactusEngine.LoadState = .idle
    @Published var partial: String = ""
    @Published var isGenerating: Bool = false

    /// Last full audio chunk from the server (base64-decoded). Consumers
    /// playing Kokoro TTS should subscribe via `onAudioChunk` instead — this
    /// property is a coalesced SwiftUI-friendly mirror of the most recent one.
    @Published var lastAudioChunk: Data?
    var onAudioChunk: ((Data) -> Void)?

    private var serverURL: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var shouldReconnect = true
    private let log = Logger(subsystem: "voice-ai-copilot", category: "RemoteRelayEngine")

    // Pending one-shot completions keyed by a nonce we inject into the system
    // prompt. The server just streams text; we correlate by matching the
    // accumulated `partial` against the active request.
    private var pendingCompletion: CheckedContinuation<String, Error>?
    private var completionBuffer: String = ""

    // Mirror of CactusEngine.generationNonce — lets OttoStore time us out
    // and route to the cloud without this engine's inbound tokens clobbering
    // `partial` after the switch.
    private var generationNonce: Int = 0

    init(urlString: String? = nil) {
        let stored = UserDefaults.standard.string(forKey: AppModeDefaults.relayURLKey)
        let resolved = urlString ?? stored ?? AppModeDefaults.fallbackRelayURL
        self.serverURL = URL(string: resolved) ?? URL(string: AppModeDefaults.fallbackRelayURL)!
    }

    func updateURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UserDefaults.standard.set(urlString, forKey: AppModeDefaults.relayURLKey)
        serverURL = url
        disconnect()
        shouldReconnect = true
        connect()
    }

    func loadIfNeeded() async {
        if case .ready = loadState { return }
        if case .loading = loadState { return }
        loadState = .loading
        connect()
    }

    func generate(prompt: String) async {
        guard await waitUntilReady() else { return }
        beginTurn()
        sendMessage(["type": "text", "data": prompt])
        sendMessage(["type": "system", "data": ""])
    }

    func generate(prompt: String, imagePath: String) async {
        guard await waitUntilReady() else { return }
        beginTurn()
        if let b64 = Self.base64JPEG(at: imagePath) {
            sendMessage(["type": "image", "data": b64])
        }
        sendMessage(["type": "text", "data": prompt])
        sendMessage(["type": "system", "data": ""])
    }

    func generate(pcmData: Data, imagePath: String?) async {
        guard await waitUntilReady() else { return }
        beginTurn()

        // PCM is chunked ~32KB to avoid 1MiB WebSocket frame limits.
        let chunkSize = 32 * 1024
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let b64 = pcmData.subdata(in: offset..<end).base64EncodedString()
            sendMessage(["type": "audio", "data": b64])
            offset = end
        }
        if let path = imagePath, let b64 = Self.base64JPEG(at: path) {
            sendMessage(["type": "image", "data": b64])
        }
        sendMessage(["type": "system", "data": ""])
    }

    private func beginTurn() {
        isGenerating = true
        partial = ""
        generationNonce &+= 1
    }

    // Abandon whatever the relay is doing. We can't tell the Mac server to
    // stop mid-turn (protocol has no cancel), but bumping the nonce makes
    // handleMessage() drop any late-arriving tokens/text so they can't
    // clobber the cloud answer we're about to switch to.
    func abandonCurrent() {
        generationNonce &+= 1
        partial = ""
        isGenerating = false
        if let cont = pendingCompletion {
            pendingCompletion = nil
            cont.resume(throwing: NSError(domain: "Otto.Relay", code: 99,
                                          userInfo: [NSLocalizedDescriptionKey: "abandoned"]))
        }
        log.notice("abandonCurrent — bumped nonce; relay will keep streaming until server finishes")
    }

    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int = 800) async throws -> String {
        if case .idle = loadState { await loadIfNeeded() }
        var waitedMs = 0
        while case .loading = loadState {
            if waitedMs >= 60_000 {
                throw NSError(domain: "Otto.Relay", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "relay still connecting after 60s"])
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            waitedMs += 150
        }
        guard case .ready = loadState else {
            throw NSError(domain: "Otto.Relay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "relay not ready: \(loadState)"])
        }

        return try await withCheckedThrowingContinuation { cont in
            self.completionBuffer = ""
            self.pendingCompletion = cont
            self.sendMessage(["type": "text", "data": "\(systemPrompt)\n\n\(userPrompt)"])
            self.sendMessage(["type": "system", "data": ""])
        }
    }

    // MARK: - Socket plumbing

    private func connect() {
        session = URLSession(configuration: .default)
        task = session?.webSocketTask(with: serverURL)
        task?.maximumMessageSize = 32 * 1024 * 1024  // TTS blobs can exceed the 1MiB default.
        task?.resume()
        receive()
    }

    private func disconnect() {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        loadState = .idle
    }

    private func sendMessage(_ message: [String: String]) {
        guard case .ready = loadState else { return }
        guard
            let data = try? JSONSerialization.data(withJSONObject: message),
            let jsonString = String(data: data, encoding: .utf8)
        else { return }

        task?.send(.string(jsonString)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.log.error("send failed: \(error.localizedDescription, privacy: .public)")
                self?.loadState = .failed(error.localizedDescription)
                self?.scheduleReconnect()
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.log.error("recv failed: \(error.localizedDescription, privacy: .public)")
                    self.loadState = .failed(error.localizedDescription)
                    self.scheduleReconnect()
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receive()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        if type == "status" {
            let status = json["status"] as? String ?? ""
            switch status {
            case "loading":
                loadState = .loading
            case "connected":
                loadState = .ready
            case "error":
                let msg = json["message"] as? String ?? "server error"
                loadState = .failed(msg)
                scheduleReconnect()
            default:
                break
            }
            return
        }

        if type == "page_image" { return } // RAG hits not wired here yet.

        guard let payload = json["data"] as? String else { return }

        switch type {
        case "token":
            // Drop tokens that arrive after abandonCurrent() — isGenerating is
            // set false there so late frames from an aborted turn can't
            // clobber the cloud answer we've switched to.
            guard isGenerating else { return }
            if let decoded = Data(base64Encoded: payload),
               let tok = String(data: decoded, encoding: .utf8) {
                partial.append(tok)
                completionBuffer.append(tok)
            }
        case "audio":
            guard isGenerating else { return }
            if let audioData = Data(base64Encoded: payload) {
                onAudioChunk?(audioData)
                lastAudioChunk = audioData
            }
        case "text":
            guard isGenerating else { return }
            // End-of-turn marker.
            if let decoded = Data(base64Encoded: payload),
               let str = String(data: decoded, encoding: .utf8) {
                partial = str
                if let cont = pendingCompletion {
                    pendingCompletion = nil
                    cont.resume(returning: str)
                    completionBuffer = ""
                }
            } else if let cont = pendingCompletion {
                pendingCompletion = nil
                cont.resume(returning: completionBuffer)
                completionBuffer = ""
            }
            isGenerating = false
        default:
            break
        }
    }

    private func waitUntilReady() async -> Bool {
        if case .idle = loadState { await loadIfNeeded() }
        var waited = 0
        while case .loading = loadState {
            if waited >= 60_000 { return false }
            try? await Task.sleep(nanoseconds: 150_000_000)
            waited += 150
        }
        if case .ready = loadState { return true }
        return false
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.shouldReconnect else { return }
            self.connect()
        }
    }

    private static func base64JPEG(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return data.base64EncodedString()
    }
}
