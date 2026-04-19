import Foundation
import AVFoundation
import Combine

/// Captures mic input, downsamples to 16 kHz mono Int16 PCM, and hands back raw bytes.
///
/// Thread model: `start()` / `stop()` are main-actor. The `installTap` callback fires on the
/// audio I/O thread — that path is `nonisolated`, touches only thread-safe state (lock-guarded
/// buffer + immutable converter reference after `start`), and never reads/writes main-actor
/// properties directly.
final class AudioRecorder: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var permissionDenied: Bool = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcmBuffer = Data()
    private let bufferLock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    @MainActor
    func start() async throws {
        guard !isRecording else { return }

        let granted = await requestMicPermission()
        if !granted {
            permissionDenied = true
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."])
        }

        let session = AVAudioSession.sharedInstance()
        // `.default` (not `.measurement`) keeps the playback path intact so AVSpeechSynthesizer
        // can play TTS through this same session after we stop recording.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        bufferLock.lock()
        pcmBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        // Capture a non-isolated reference so the audio thread never touches self's main-actor
        // isolation. Converter + targetFormat are immutable once start() returns.
        let localConverter = converter!
        let localFormat = targetFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.appendConverted(buffer: buffer, converter: localConverter, targetFormat: localFormat)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    @MainActor
    func stop() -> Data {
        guard isRecording else { return Data() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Deliberately do NOT deactivate the audio session here — AVSpeechSynthesizer
        // needs an active `.playAndRecord` session to speak the model's reply back.
        isRecording = false

        bufferLock.lock()
        let out = pcmBuffer
        pcmBuffer = Data()
        bufferLock.unlock()
        return out
    }

    /// Called on the audio I/O thread. Must stay nonisolated and touch only thread-safe state.
    private nonisolated func appendConverted(buffer: AVAudioPCMBuffer,
                                             converter: AVAudioConverter,
                                             targetFormat: AVAudioFormat) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error,
              outBuffer.frameLength > 0,
              let channelData = outBuffer.int16ChannelData else { return }

        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        let appended = Data(bytes: channelData[0], count: byteCount)

        bufferLock.lock()
        pcmBuffer.append(appended)
        bufferLock.unlock()
    }

    @MainActor
    private func requestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }
}
