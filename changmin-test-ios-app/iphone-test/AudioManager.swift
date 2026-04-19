//
//  AudioManager.swift
//  iphone-test
//

import AVFoundation
import Foundation

final class AudioManager: NSObject {

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000
    private var isCapturing = false
    private var onChunk: ((String) -> Void)?

    // Playback
    private var playerNode = AVAudioPlayerNode()
    private let playerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16000,
                                             channels: 1,
                                             interleaved: true)!

    // TTS fallback
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        configureAudioSession()
        setupPlaybackGraph()
    }

    // MARK: - Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                  mode: .default,
                                  options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setActive(true)
    }

    // MARK: - Capture

    func startCapture(onChunk: @escaping (String) -> Void) {
        guard !isCapturing else { return }
        self.onChunk = onChunk
        isCapturing = true

        let input = engine.inputNode
        // outputFormat(forBus:) is always valid on real hardware; inputFormat(forBus:)
        // can return a zero-sample-rate format before the engine is started, which
        // causes the "IsFormatSampleRateAndChannelCountValid" assertion crash on device.
        let inputFormat = input.outputFormat(forBus: 0)

        // Converter from device native format → 16 kHz mono Int16
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true)!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isCapturing else { return }

            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

            var error: NSError?
            var inputConsumed = false
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                inputConsumed = true
                return buffer
            }

            guard error == nil, convertedBuffer.frameLength > 0,
                  let channelData = convertedBuffer.int16ChannelData else { return }

            let frameCount = Int(convertedBuffer.frameLength)
            let ptr = channelData[0]
            let rawData = Data(bytes: ptr, count: frameCount * 2) // 2 bytes per Int16
            let encoded = rawData.base64EncodedString()
            self.onChunk?(encoded)
        }

        try? engine.start()
    }

    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        engine.inputNode.removeTap(onBus: 0)
        // Do NOT stop the engine — it must keep running so playPCM16 can
        // schedule and play response audio immediately after recording ends.
    }

    // MARK: - Playback

    private func setupPlaybackGraph() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playerFormat)
        // Do NOT start the engine here — starting it during init can briefly
        // interrupt the camera session and races with audio session activation.
        // The engine is started lazily in playPCM16() and startCapture().
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func playPCM16(_ data: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let frameCount = data.count / 2
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.playerFormat,
                                                frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channelData = buffer.int16ChannelData else { return }

            data.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(channelData[0], src, data.count)
            }

            if !self.engine.isRunning {
                try? self.engine.start()
            }
            self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }
        }
    }
}
