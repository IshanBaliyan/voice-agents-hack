import SwiftUI

private enum SpotifyPalette {
    static let background = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.11)       // #1C1C1C
    static let field = Color(red: 0.18, green: 0.18, blue: 0.18)      // #2E2E2E
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)  // #1DB954
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.7)
    static let danger = Color(red: 0.95, green: 0.3, blue: 0.3)
}

struct ContentView: View {
    @StateObject private var engine = CactusEngine()
    @StateObject private var speaker = Speaker()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var camera = CameraCapture()
    @State private var prompt: String = ""
    @State private var micError: String?
    @State private var includeCamera: Bool = true
    @FocusState private var promptFocused: Bool

    var body: some View {
        ZStack {
            SpotifyPalette.background.ignoresSafeArea()

            VStack(spacing: 16) {
                header
                statusPill
                responseCard
                cameraToggleRow
                if includeCamera && recorder.isRecording {
                    cameraPreview
                }
                inputRow
                micButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .task { await engine.loadIfNeeded() }
        .onChange(of: engine.partial) { oldValue, newValue in
            guard newValue.hasPrefix(oldValue) else {
                speaker.reset()
                return
            }
            let delta = String(newValue.dropFirst(oldValue.count))
            if !delta.isEmpty { speaker.append(delta) }
        }
        .onChange(of: engine.isGenerating) { _, generating in
            if !generating { speaker.finish() }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Voice Copilot")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(SpotifyPalette.primaryText)
                .kerning(-0.5)
            Spacer()
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SpotifyPalette.secondaryText)
            Spacer()
        }
    }

    private var responseCard: some View {
        ScrollView {
            Text(engine.partial.isEmpty ? placeholderText : engine.partial)
                .font(.system(size: 17))
                .foregroundStyle(engine.partial.isEmpty ? SpotifyPalette.secondaryText : SpotifyPalette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .background(SpotifyPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var cameraToggleRow: some View {
        HStack(spacing: 10) {
            Image(systemName: includeCamera ? "camera.fill" : "camera")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(includeCamera ? SpotifyPalette.accent : SpotifyPalette.secondaryText)
            Text("Include camera with mic")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SpotifyPalette.secondaryText)
            Spacer()
            Toggle("", isOn: $includeCamera)
                .labelsHidden()
                .tint(SpotifyPalette.accent)
                .disabled(recorder.isRecording || engine.isGenerating)
        }
        .padding(.horizontal, 4)
    }

    private var cameraPreview: some View {
        CameraPreviewView(session: camera.session)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(SpotifyPalette.accent, lineWidth: 2)
            )
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            TextField("Ask Gemma…", text: $prompt, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16))
                .foregroundStyle(SpotifyPalette.primaryText)
                .tint(SpotifyPalette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(SpotifyPalette.field)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focused($promptFocused)
                .submitLabel(.send)
                .onSubmit(sendText)
                .disabled(engine.isGenerating || recorder.isRecording)

            Button(action: sendText) {
                Image(systemName: engine.isGenerating ? "ellipsis" : "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(isSendable ? SpotifyPalette.accent : SpotifyPalette.secondaryText.opacity(0.4))
                    .clipShape(Circle())
            }
            .disabled(!isSendable)
        }
    }

    private var micButton: some View {
        VStack(spacing: 8) {
            Button(action: toggleMic) {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? SpotifyPalette.danger : SpotifyPalette.accent)
                        .frame(width: 72, height: 72)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .disabled(!isMicEnabled)
            .opacity(isMicEnabled ? 1.0 : 0.4)

            if let micError {
                Text(micError)
                    .font(.caption)
                    .foregroundStyle(SpotifyPalette.danger)
            } else {
                Text(micHint)
                    .font(.caption)
                    .foregroundStyle(SpotifyPalette.secondaryText)
            }
        }
    }

    // MARK: - State

    private var micHint: String {
        if recorder.isRecording {
            return includeCamera ? "Tap to stop — audio + photo will be sent" : "Tap to stop and send"
        }
        return includeCamera ? "Tap to speak (camera will capture on stop)" : "Tap to speak"
    }

    private var placeholderText: String {
        switch engine.loadState {
        case .loading: return "Loading Gemma 4 E4B on-device…"
        case .ready:   return "Type a question below, or tap the mic."
        case .idle:    return "Starting up…"
        case .failed:  return "Model failed to load."
        }
    }

    private var statusText: String {
        if recorder.isRecording { return includeCamera ? "Listening + watching…" : "Listening…" }
        switch engine.loadState {
        case .idle:    return "Idle"
        case .loading: return "Loading model"
        case .ready:   return engine.isGenerating ? "Thinking" : "Ready · on-device"
        case .failed(let msg): return msg
        }
    }

    private var statusColor: Color {
        if recorder.isRecording { return SpotifyPalette.danger }
        switch engine.loadState {
        case .ready:  return SpotifyPalette.accent
        case .failed: return SpotifyPalette.danger
        default:      return SpotifyPalette.secondaryText
        }
    }

    private var isSendable: Bool {
        if engine.isGenerating || recorder.isRecording { return false }
        guard case .ready = engine.loadState else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isMicEnabled: Bool {
        if engine.isGenerating { return false }
        if case .ready = engine.loadState { return true }
        return recorder.isRecording
    }

    // MARK: - Actions

    private func sendText() {
        guard isSendable else { return }
        let text = prompt
        prompt = ""
        promptFocused = false
        speaker.reset()
        Task { await engine.generate(prompt: text) }
    }

    private func toggleMic() {
        if recorder.isRecording {
            stopMicAndSend()
        } else {
            startMic()
        }
    }

    private func startMic() {
        micError = nil
        promptFocused = false
        speaker.reset()
        Task {
            do {
                // Order matters: camera first so AVCaptureSession doesn't race with the audio
                // session reconfigure. `automaticallyConfiguresApplicationAudioSession = false`
                // on the capture session keeps the two from fighting on the singleton.
                if includeCamera {
                    try await camera.start()
                }
                try await recorder.start()
            } catch {
                micError = error.localizedDescription
                camera.stop()
            }
        }
    }

    private func stopMicAndSend() {
        let pcm = recorder.stop()
        guard !pcm.isEmpty else {
            micError = "No audio captured."
            camera.stop()
            return
        }

        if includeCamera {
            Task {
                let imageURL = await camera.capture()
                camera.stop()
                await engine.generate(pcmData: pcm, imagePath: imageURL?.path)
            }
        } else {
            Task { await engine.generate(pcmData: pcm) }
        }
    }
}

#Preview { ContentView() }
