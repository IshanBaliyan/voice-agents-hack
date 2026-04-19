//
//  WebSocketManager.swift
//  iphone-test
//

import Foundation

enum WSState: Equatable {
    case disconnected, connecting, connected, error(String)
}

@MainActor
@Observable
final class WebSocketManager {

    var state: WSState = .disconnected
    var lastTextResponse: String = ""
    var lastAudioData: Data? = nil
    /// Accumulates streamed tokens for the current turn; reset whenever a new
    /// final `audio` / `text` blob arrives (that marks end-of-turn).
    var streamedText: String = ""
    /// Optional callback invoked for every incoming `type:audio` chunk.
    /// Unlike `lastAudioData`, this fires once per chunk even if chunks
    /// arrive back-to-back, so streamed sentence-level Kokoro audio can
    /// be queued into the player without losing frames to SwiftUI
    /// coalescing.
    var onAudioChunk: ((Data) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var serverURL: URL
    private var shouldReconnect = true

    init(urlString: String) {
        self.serverURL = URL(string: urlString)
            ?? URL(string: "wss://68bd-50-175-245-62.ngrok-free.app/ws")!
        connect()
    }

    func updateURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        serverURL = url
        disconnect()
        shouldReconnect = true
        connect()
    }

    func connect() {
        state = .connecting
        urlSession = URLSession(configuration: .default)
        task = urlSession?.webSocketTask(with: serverURL)
        // Default is 1 MiB; long TTS replies (~1–2 MB base64) get dropped and
        // kill the socket. Raise to 32 MiB so full audio frames go through.
        task?.maximumMessageSize = 32 * 1024 * 1024
        task?.resume()
        // Stay in .connecting — the server will send {"type":"status","status":"connected"}
        // once the model is ready.  Periodic {"type":"status","status":"loading"} pings
        // keep the socket alive during long model loads.
        receive()
    }

    func disconnect() {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    func send(_ message: [String: String]) {
        guard state == .connected else { return }
        guard
            let data = try? JSONSerialization.data(withJSONObject: message),
            let jsonString = String(data: data, encoding: .utf8)
        else { return }

        task?.send(.string(jsonString)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.state = .error(error.localizedDescription)
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
                    self.state = .error(error.localizedDescription)
                    self.scheduleReconnect()
                case .success(let message):
                    switch message {
                    case .string(let text):      self.handleMessage(text)
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

        // Handle server-side status messages
        if type == "status" {
            let status = json["status"] as? String ?? ""
            switch status {
            case "loading":
                // Keep-alive ping during model load — stay in .connecting
                break
            case "connected":
                state = .connected
            case "error":
                let msg = json["message"] as? String ?? "Server error"
                state = .error(msg)
                scheduleReconnect()
            default:
                break
            }
            return
        }

        // Handle payload messages
        guard let payload = json["data"] as? String else { return }

        switch type {
        case "token":
            // Streaming token from the model. If this is the first token of a
            // new turn (previous turn ended with an audio/text blob), reset
            // the buffer so we don't concat across turns.
            if !lastTextResponse.isEmpty || lastAudioData != nil {
                streamedText = ""
                lastTextResponse = ""
                lastAudioData = nil
            }
            if let decoded = Data(base64Encoded: payload),
               let tok = String(data: decoded, encoding: .utf8) {
                streamedText += tok
            }
        case "audio":
            guard let audioData = Data(base64Encoded: payload) else { return }
            // Direct callback path — each chunk is queued into the audio
            // player immediately, without waiting for SwiftUI to diff
            // `lastAudioData`. Back-to-back Kokoro sentences therefore
            // play seamlessly.
            onAudioChunk?(audioData)
            lastAudioData = audioData
        case "text":
            if let decoded = Data(base64Encoded: payload),
               let str = String(data: decoded, encoding: .utf8) {
                lastTextResponse = str
            } else {
                lastTextResponse = payload
            }
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.shouldReconnect else { return }
            self.connect()
        }
    }
}
