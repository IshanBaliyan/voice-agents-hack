//
//  ContentView.swift
//  iphone-test
//

import SwiftUI
import AVFoundation

struct ContentView: View {

    // MARK: - State

    @State private var wsManager: WebSocketManager
    @State private var cameraManager = CameraManager()
    @State private var audioManager = AudioManager()

    @State private var serverURL = "wss://4e0b-50-175-245-62.ngrok-free.app/ws"
    @State private var isRecording = false
    @State private var statusText = "Connecting…"
    @State private var responseText = ""


    // MARK: - Init

    init() {
        let url = "wss://4e0b-50-175-245-62.ngrok-free.app/ws"
        let manager = WebSocketManager(urlString: url)
        _wsManager = State(wrappedValue: manager)
        // Forward every streamed audio chunk straight into the player so
        // back-to-back Kokoro sentences queue up without frame loss.
        let player = audioManager
        manager.onAudioChunk = { data in
            player.playPCM16(data)
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {

                // Server URL field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server URL")
                        .font(.caption)
                        .foregroundColor(.gray)
                    TextField("ws://…", text: $serverURL)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit {
                            wsManager.updateURL(serverURL)
                        }
                        .accessibilityLabel("Server URL")
                }
                .padding(.horizontal)

                // Status label
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(statusColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .accessibilityLabel("Status: \(statusText)")

                // Camera preview
                CameraPreviewView(session: cameraManager.captureSession)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                    .accessibilityLabel("Camera preview")

                // Retrieved page image (RAG hit from the server)
                retrievedPageSection

                // Response label
                ScrollView {
                    Text(responseText.isEmpty ? "No response yet" : responseText)
                        .font(.body)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 140)
                .background(Color.white.opacity(0.07))
                .cornerRadius(12)
                .padding(.horizontal)
                .accessibilityLabel("Last response: \(responseText)")

                Spacer()

                // PTT Button
                pttButton

                Spacer(minLength: 32)
            }
            .padding(.top, 16)
        }
        .onChange(of: wsManager.state) { _, state in
            updateStatus(state)
        }
        .onChange(of: wsManager.streamedText) { _, text in
            // Live-render tokens as they arrive from the model.
            if !text.isEmpty {
                responseText = text
                if wsManager.state == .connected { statusText = "Streaming…" }
            }
        }
        .onChange(of: wsManager.lastTextResponse) { _, text in
            if !text.isEmpty {
                responseText = text
                audioManager.speak(text)
                if wsManager.state == .connected { statusText = "Ready" }
            }
        }
        .onChange(of: wsManager.lastAudioData) { _, data in
            // Playback itself is handled by the `onAudioChunk` callback wired
            // in init(). This observer only updates status so the UI reflects
            // that a response arrived.
            guard data != nil else { return }
            if wsManager.state == .connected { statusText = "Ready" }
        }
    }

    // MARK: - Retrieved pages (RAG)
    //
    // Shown as a compact row of citation chips ([1], [2], …) matching the
    // `[N]` markers Gemma emits inline. Tapping a chip opens the full page
    // image in a modal sheet.

    @State private var presentedPage: RetrievedPage?

    @ViewBuilder
    private var retrievedPageSection: some View {
        let pages = wsManager.retrievedPages
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundColor(.accentColor)
                    Text("Sources — tap to view")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pages) { page in
                            Button {
                                presentedPage = page
                            } label: {
                                HStack(spacing: 6) {
                                    Text("[\(page.citation)]")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundColor(.accentColor)
                                    Text("\(page.source) · p. \(page.page)")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Reference \(page.citation), \(page.source) page \(page.page). Tap to view."
                            )
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.07))
            .cornerRadius(12)
            .padding(.horizontal)
            .transition(.opacity)
            .sheet(item: $presentedPage) { page in
                PageViewerSheet(page: page)
            }
        }
    }

    // MARK: - PTT Button

    private var pttButton: some View {
        Circle()
            .fill(isRecording
                ? LinearGradient(colors: [Color.red, Color(red: 0.9, green: 0.1, blue: 0.2)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)
                : LinearGradient(colors: [Color.blue, Color(red: 0.1, green: 0.4, blue: 0.9)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 160, height: 160)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                    Text(isRecording ? "Recording…" : "Hold to Talk")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            )
            .shadow(color: isRecording ? .red.opacity(0.7) : .blue.opacity(0.4), radius: isRecording ? 30 : 20)
            .scaleEffect(isRecording ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isRecording { beginRecording() }
                    }
                    .onEnded { _ in
                        if isRecording { endRecording() }
                    }
            )
            .accessibilityLabel(isRecording ? "Recording. Release to send." : "Hold to Talk")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Recording flow

    private func beginRecording() {
        guard wsManager.state == .connected else { return }
        isRecording = true
        statusText = "Recording"

        // Audio tap fires on a realtime thread — hop to MainActor before touching wsManager.
        audioManager.startCapture { base64Chunk in
            Task { @MainActor in
                wsManager.send(["type": "audio", "data": base64Chunk])
            }
        }
    }

    private func endRecording() {
        isRecording = false
        audioManager.stopCapture()
        statusText = "Processing…"

        cameraManager.capturePhoto { base64Image in
            if let img = base64Image {
                wsManager.send(["type": "image", "data": img])
            }
            wsManager.send(["type": "system", "data": ""])
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch wsManager.state {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .error:        return .red
        case .disconnected: return .gray
        }
    }

    private func updateStatus(_ state: WSState) {
        switch state {
        case .connecting:           statusText = "Loading model…"
        case .connected:            if !isRecording { statusText = "Ready" }
        case .disconnected:         statusText = "Disconnected"
        case .error(let msg):       statusText = "Error: \(msg)"
        }
    }
}

// MARK: - Full-page viewer

/// Modal shown when the user taps a citation chip. Displays the retrieved
/// PDF page at full size with pinch-to-zoom.
private struct PageViewerSheet: View {
    let page: RetrievedPage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: page.image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { zoom = max(1.0, min($0, 4.0)) }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { zoom = zoom > 1.0 ? 1.0 : 2.0 }
                    }
            }
            .background(Color.white)
            .navigationTitle("[\(page.citation)] \(page.source)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("p. \(page.page) · \(String(format: "%.2f", page.score))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
