import Foundation
import AVFoundation
import Speech
import Combine

// MARK: - Speech Recognizer

@MainActor
final class SpeechRecognizer: NSObject, ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false
    @Published var lastError: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func requestAuthorization() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        let micOK: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        return speechOK && micOK
    }

    func start() throws {
        guard !isListening else { return }
        transcript = ""
        lastError = nil

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }
}

// MARK: - Speaker (TTS)

@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking: Bool = false
    private let synth = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, onFinish: (() -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onFinish?(); return }
        self.onFinish = onFinish

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let utter = AVSpeechUtterance(string: trimmed)
        utter.voice = AVSpeechSynthesisVoice(language: "en-US")
        utter.rate = 0.48
        utter.pitchMultiplier = 1.0
        isSpeaking = true
        synth.speak(utter)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onFinish?()
            self.onFinish = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onFinish = nil
        }
    }
}

// MARK: - Streaming PCM16 player
//
// Plays raw int16 LE mono PCM at 24kHz (Kokoro's native output) as it arrives
// from the Mac relay. Mirrors changmin-test-ios-app/AudioManager.playPCM16 but
// as a self-contained engine so Otto can own it without entangling the
// recording path.
@MainActor
final class PCM16StreamPlayer: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    /// Number of chunks currently queued or playing. Flips to 0 when the
    /// last scheduled buffer's completion handler fires.
    @Published private(set) var inFlight: Int = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 24_000,
                                       channels: 1,
                                       interleaved: true)!

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Enqueue a chunk of 16-bit LE mono PCM at 24kHz. Starts the engine and
    /// the player node lazily on the first chunk of a turn.
    func enqueue(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.int16ChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                memcpy(channel[0], src, data.count)
            }
        }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, options: [.duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        if !engine.isRunning { try? engine.start() }

        inFlight += 1
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = max(0, self.inFlight - 1)
                if self.inFlight == 0 { self.isPlaying = false }
            }
        }
        if !node.isPlaying { node.play() }
        isPlaying = true
    }

    func stop() {
        node.stop()
        inFlight = 0
        isPlaying = false
    }
}
