import Foundation
import SwiftUI
import Combine
import AVFoundation
import os

/// Server-backed replacement for the on-device Cactus engine. Keeps the same
/// public API (`loadState`, `partial`, `isGenerating`, `loadIfNeeded`, the
/// `generate(...)` family) so the SwiftUI layer does not need to change, but
/// routes every request over a WebSocket to the Mac-side cactus_server that
/// holds the Gemma + Kokoro pipeline.
///
/// Wire protocol (matches cactus_server/server.py):
///   Outbound:
///     {type:"audio",  data:"<base64 PCM16>"} — streamed during recording
///     {type:"image",  data:"<base64 JPEG>"}  — one-shot before trigger
///     {type:"system", data:""}               — trigger generation
///   Inbound:
///     {type:"status", status:"ready|loading|error", message?:""}
///     {type:"token",  data:"<base64 UTF-8>"}  — streamed tokens
///     {type:"text",   data:"<base64 UTF-8>"}  — final text (when TTS unavailable)
///     {type:"audio",  data:"<base64 PCM16>"}  — final Kokoro TTS blob
@MainActor
final class CactusEngine: ObservableObject {
    enum LoadState { case idle, loading, ready, failed(String) }

    @Published var loadState: LoadState = .idle
    @Published var partial: String = ""
    @Published var isGenerating: Bool = false
    /// True while Kokoro PCM is actively draining through the player. The Otto
    /// orb reads this to render `.speaking`, which is distinct from
    /// `isGenerating` (that covers thinking before TTS starts).
    @Published var isPlayingAudio: Bool = false

    /// Override at runtime if the ngrok URL changes.
    static var serverURL: String = "wss://guts-trinity-abacus.ngrok-free.dev/ws"

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connectedContinuation: CheckedContinuation<Void, Error>?
    private var turnContinuation: CheckedContinuation<Void, Never>?

    private lazy var player: PCMPlayer = PCMPlayer { [weak self] active in
        Task { @MainActor [weak self] in
            self?.isPlayingAudio = active
        }
    }
    private let log = Logger(subsystem: "voice-ai-copilot", category: "CactusEngine.Server")

    // MARK: - Public API

    func loadIfNeeded() async {
        if case .ready = loadState { return }
        if case .loading = loadState { return }
        loadState = .loading

        do {
            try await connect()
            loadState = .ready
        } catch {
            loadState = .failed("Server unavailable: \(error.localizedDescription)")
        }
    }

    func generate(prompt: String) async {
        await generate(prompt: prompt, imagePath: nil)
    }

    func generate(prompt: String, imagePath: String) async {
        await generate(prompt: prompt, imagePath: Optional(imagePath))
    }

    func generate(pcmData: Data, imagePath: String? = nil) async {
        await runTurn(pcmData: pcmData, imagePath: imagePath)
    }

    /// Stop Kokoro playback mid-turn. The underlying generate() call still runs
    /// to completion — we just drop any remaining audio chunks on the floor.
    func interruptAudio() {
        player.reset()
    }

    // MARK: - Prompt-only / prompt+image turns

    private func generate(prompt: String, imagePath: String?) async {
        // The server has no text-prompt entry point; it triggers on
        // pending-audio + pending-image when a "system" frame arrives. A
        // text-only request would therefore just hang, so we surface that
        // explicitly instead of letting the UI spin.
        if imagePath == nil {
            partial = "(Server backend requires voice or camera input — text-only prompts aren't supported in this build.)"
            return
        }
        await runTurn(pcmData: nil, imagePath: imagePath)
    }

    // MARK: - Turn execution

    private func runTurn(pcmData: Data?, imagePath: String?) async {
        guard case .ready = loadState else { return }
        isGenerating = true
        partial = ""
        player.reset()

        if let pcmData, !pcmData.isEmpty {
            // Server concatenates audio chunks into a rolling buffer. Sending
            // in ~64 KiB slices keeps frames well under the 32 MiB cap and
            // matches how the live mic path would stream.
            let chunkSize = 64 * 1024
            var offset = 0
            while offset < pcmData.count {
                let end = min(offset + chunkSize, pcmData.count)
                let slice = pcmData.subdata(in: offset..<end)
                send(["type": "audio", "data": slice.base64EncodedString()])
                offset = end
            }
        }

        if let imagePath, let image = FileManager.default.contents(atPath: imagePath) {
            send(["type": "image", "data": image.base64EncodedString()])
        }

        send(["type": "system", "data": ""])

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.turnContinuation = cont
        }

        isGenerating = false
    }

    // MARK: - WebSocket

    private func connect() async throws {
        guard let url = URL(string: Self.serverURL) else {
            throw NSError(domain: "CactusEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad server URL"])
        }

        urlSession = URLSession(configuration: .default)
        task = urlSession?.webSocketTask(with: url)
        task?.maximumMessageSize = 32 * 1024 * 1024
        task?.resume()
        receive()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectedContinuation = cont
            // Cap the wait at 30 s — first boot loads Gemma weights, which
            // can be slow, but an unbounded wait would hang the Loading UI.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if let pending = self.connectedContinuation {
                    self.connectedContinuation = nil
                    pending.resume(throwing: NSError(
                        domain: "CactusEngine", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for server ready"]))
                }
            }
        }
    }

    private func send(_ message: [String: String]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: message),
            let jsonString = String(data: data, encoding: .utf8)
        else { return }

        task?.send(.string(jsonString)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.log.error("ws.send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.log.error("ws.receive failed: \(error.localizedDescription, privacy: .public)")
                    if let pending = self.connectedContinuation {
                        self.connectedContinuation = nil
                        pending.resume(throwing: error)
                    }
                    if let pending = self.turnContinuation {
                        self.turnContinuation = nil
                        pending.resume()
                    }
                    self.loadState = .failed(error.localizedDescription)
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default: break
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
            case "ready", "connected":
                if let pending = connectedContinuation {
                    connectedContinuation = nil
                    pending.resume()
                }
            case "loading":
                break
            case "error":
                let msg = json["message"] as? String ?? "Server error"
                if let pending = connectedContinuation {
                    connectedContinuation = nil
                    pending.resume(throwing: NSError(
                        domain: "CactusEngine", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            default: break
            }
            return
        }

        guard let payload = json["data"] as? String else { return }

        switch type {
        case "token":
            if let decoded = Data(base64Encoded: payload),
               let tok = String(data: decoded, encoding: .utf8) {
                partial += tok
            }
        case "text":
            if let decoded = Data(base64Encoded: payload),
               let str = String(data: decoded, encoding: .utf8) {
                partial = str
            }
            finishTurn()
        case "audio":
            if let audio = Data(base64Encoded: payload) {
                player.play(audio)
            }
            finishTurn()
        default: break
        }
    }

    private func finishTurn() {
        if let pending = turnContinuation {
            turnContinuation = nil
            pending.resume()
        }
    }

    deinit {
        task?.cancel(with: .goingAway, reason: nil)
    }
}

// MARK: - 24 kHz Int16 PCM playback for Kokoro TTS

private final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 24_000,
                                       channels: 1,
                                       interleaved: true)!
    private var configured = false

    /// Increment/decrement around scheduled buffers. Flips the observer true
    /// on the leading edge (first buffer queued) and false on the trailing edge
    /// (last buffer drained), which maps cleanly to VoiceState.speaking.
    private let counterLock = NSLock()
    private var pending = 0
    private let onActiveChanged: (Bool) -> Void

    init(onActiveChanged: @escaping (Bool) -> Void) {
        self.onActiveChanged = onActiveChanged
    }

    func play(_ data: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }

            let frames = data.count / 2
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.format,
                                                frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.int16ChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            data.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(channel[0], src, data.count)
            }

            if !self.engine.isRunning { try? self.engine.start() }

            self.counterLock.lock()
            let wasIdle = self.pending == 0
            self.pending += 1
            self.counterLock.unlock()
            if wasIdle { self.onActiveChanged(true) }

            self.node.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                self.counterLock.lock()
                self.pending -= 1
                let drained = self.pending == 0
                self.counterLock.unlock()
                if drained { self.onActiveChanged(false) }
            }
            if !self.node.isPlaying { self.node.play() }
        }
    }

    func reset() {
        guard configured else { return }
        node.stop()
        counterLock.lock()
        let wasActive = pending > 0
        pending = 0
        counterLock.unlock()
        if wasActive { onActiveChanged(false) }
    }

    private func configure() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        configured = true
    }
}
