import Foundation
import AVFoundation
import Combine

@MainActor
final class Speaker: ObservableObject {
    private let synth = AVSpeechSynthesizer()
    private var buffer: String = ""
    private let sentenceTerminators: Set<Character> = [".", "!", "?", "\n"]

    func append(_ chunk: String) {
        buffer.append(chunk)
        flushCompleteSentences()
    }

    func finish() {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { enqueue(trimmed) }
        buffer = ""
    }

    func reset() {
        synth.stopSpeaking(at: .immediate)
        buffer = ""
    }

    private func flushCompleteSentences() {
        while let idx = buffer.firstIndex(where: { sentenceTerminators.contains($0) }) {
            let sentence = String(buffer[...idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...idx)
            enqueue(sentence)
        }
    }

    private func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }
}
