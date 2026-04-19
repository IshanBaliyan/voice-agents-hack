//
//  WebSocketManager.swift
//  iphone-test
//

import Foundation
import UIKit

/// Metadata + decoded image for the most recent RAG hit forwarded by the
/// model server. Emitted once per conversational turn when the transcribed
/// query matches a PDF page above the server's score threshold.
struct RetrievedPage: Equatable, Identifiable {
    let id = UUID()
    let image: UIImage
    let source: String
    let page: Int
    let score: Double
    let query: String
    let rank: Int
    let total: Int
    let receivedAt: Date

    static func == (lhs: RetrievedPage, rhs: RetrievedPage) -> Bool {
        lhs.id == rhs.id
    }
}

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
    /// Pages retrieved by the server-side RAG pipeline for the *current*
    /// turn. Cleared when a new query's first frame arrives (detected via
    /// a change of `query` string), then appended as subsequent frames
    /// stream in for the same query.
    var retrievedPages: [RetrievedPage] = []

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var serverURL: URL
    private var shouldReconnect = true

    init(urlString: String) {
        self.serverURL = URL(string: urlString)
            ?? URL(string: "wss://4e0b-50-175-245-62.ngrok-free.app/ws")!
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

        // page_image frames carry extra metadata alongside `data` — handle
        // them before the generic `payload` unwrap below.
        if type == "page_image" {
            guard
                let payload = json["data"] as? String,
                let bytes = Data(base64Encoded: payload),
                let image = UIImage(data: bytes)
            else { return }
            let source = json["source"] as? String ?? ""
            let page = (json["page"] as? Int)
                ?? Int(json["page"] as? Double ?? 0)
            let score = (json["score"] as? Double)
                ?? Double(json["score"] as? Int ?? 0)
            let query = json["query"] as? String ?? ""
            let rank = (json["rank"] as? Int)
                ?? Int(json["rank"] as? Double ?? 0)
            let total = (json["total"] as? Int)
                ?? Int(json["total"] as? Double ?? 0)

            // First frame of a new query? Clear the previous turn's pages.
            // Subsequent frames (same query) get appended so the carousel
            // fills in as images arrive.
            if retrievedPages.first?.query != query {
                retrievedPages = []
            }
            retrievedPages.append(RetrievedPage(
                image: image,
                source: source,
                page: page,
                score: score,
                query: query,
                rank: rank,
                total: total,
                receivedAt: Date()
            ))
            // Keep pages ordered by server rank so the carousel is stable
            // even if frames arrive out of order.
            retrievedPages.sort { $0.rank < $1.rank }
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
