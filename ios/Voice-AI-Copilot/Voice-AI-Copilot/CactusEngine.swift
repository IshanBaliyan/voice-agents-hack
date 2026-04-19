import Foundation
import SwiftUI
import Combine
import os
import Darwin

@MainActor
final class CactusEngine: ObservableObject {
    enum LoadState { case idle, loading, ready, failed(String) }

    @Published var loadState: LoadState = .idle
    @Published var partial: String = ""
    @Published var isGenerating: Bool = false

    private var model: CactusModelT?
    private let log = Logger(subsystem: "voice-ai-copilot", category: "CactusEngine")

    func loadIfNeeded() async {
        if case .ready = loadState { return }
        if case .loading = loadState { return }
        loadState = .loading

        // --- [stage 1] resolve weights path -----------------------------------------------------
        let devPath = "/Users/ishan/Development/yc-voice-april-2026/yc-voice-v2/cactus/weights/gemma-4-e4b-it"
        let bundleRoot = Bundle.main.resourcePath ?? ""
        let bundleNested = bundleRoot + "/gemma-4-e4b-it"
        let cachesNested = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? "") + "/gemma-4-e4b-it"
        let candidates = [devPath, bundleNested, bundleRoot, cachesNested]

        log.info("load.stage1.resolve — candidates=\(candidates, privacy: .public)")
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/config.txt") }) else {
            let msg = "Model weights not found. Checked: \(candidates.joined(separator: ", "))"
            log.error("load.stage1.resolve FAILED — \(msg, privacy: .public)")
            loadState = .failed(msg)
            return
        }
        log.info("load.stage1.resolve OK — path=\(path, privacy: .public)")

        // --- [stage 2] enumerate weights on disk ------------------------------------------------
        logWeightsInventory(path: path)

        // --- [stage 3] capture memory state before init -----------------------------------------
        let avail0 = availableMemoryMB()
        let footprint0 = memoryFootprintMB()
        log.info("load.stage3.memory — before cactus_init: availableMB=\(avail0) footprintMB=\(footprint0)")

        // --- [stage 4] call cactus_init with timing ---------------------------------------------
        let t0 = Date()
        log.info("load.stage4.init — calling cactus_init(path, nil, false)")
        do {
            let handle = try await Task.detached(priority: .userInitiated) {
                try cactusInit(path, nil, false)
            }.value
            let dt = Date().timeIntervalSince(t0)
            let avail1 = availableMemoryMB()
            let footprint1 = memoryFootprintMB()
            log.info("load.stage4.init OK — took=\(dt, format: .fixed(precision: 2))s availableMB=\(avail1) footprintMB=\(footprint1) Δfootprint=\(footprint1 - footprint0)MB")

            // cactus sometimes leaves a non-fatal message in last-error even on success.
            let residual = cactusGetLastError()
            if !residual.isEmpty { log.notice("load.stage4.init residual lastError=\(residual, privacy: .public)") }

            self.model = handle
            self.loadState = .ready
        } catch {
            let dt = Date().timeIntervalSince(t0)
            let cactusErr = cactusGetLastError()
            let avail1 = availableMemoryMB()
            let footprint1 = memoryFootprintMB()
            let detail = "cactus_init FAILED after \(String(format: "%.2f", dt))s — availableMB=\(avail1) footprintMB=\(footprint1) swiftErr=\(error.localizedDescription) cactusErr=\(cactusErr)"
            log.error("load.stage4.init FAILED — \(detail, privacy: .public)")
            self.loadState = .failed(detail)
        }
    }

    func generate(prompt: String) async {
        await runCompletion(userPrompt: prompt, pcmData: nil)
    }

    func generate(prompt: String, imagePath: String) async {
        await runCompletion(userPrompt: prompt, pcmData: nil, imagePath: imagePath)
    }

    func generate(pcmData: Data, imagePath: String? = nil) async {
        let prompt = imagePath == nil
            ? "Answer the user's spoken question in plain English."
            : "Answer the user's spoken question about what they're pointing the camera at, in plain English."
        await runCompletion(userPrompt: prompt, pcmData: pcmData, imagePath: imagePath)
    }

    private func runCompletion(userPrompt: String, pcmData: Data?, imagePath: String? = nil) async {
        guard let model else {
            log.error("complete.stage0.guard — model handle is nil (loadIfNeeded never completed?)")
            return
        }
        isGenerating = true
        partial = ""

        // --- [stage 1] sanity check image path --------------------------------------------------
        // Cactus's vision encoder uses stb_image, which only decodes JPEG/PNG/BMP/GIF/TGA/PSD/HDR/PIC.
        // HEIC is unsupported — if we hand it a HEIC file stb_image throws and prefill dies silently
        // with an empty cactus_get_last_error. So we check the magic bytes here and refuse HEIC
        // rather than letting the native side explode.
        var safeImagePath: String? = nil
        var imageDiag: String = "none"
        if let imagePath {
            if let probe = probeImageFile(imagePath) {
                imageDiag = "format=\(probe.format) bytes=\(probe.size) magic=\(probe.magicHex)"
                log.info("complete.stage1.image — path=\(imagePath, privacy: .public) \(imageDiag, privacy: .public)")
                if probe.stbiSupported {
                    safeImagePath = imagePath
                } else {
                    imageDiag += " REJECTED_UNSUPPORTED"
                    log.error("complete.stage1.image — REJECTED format=\(probe.format, privacy: .public) not supported by stb_image; dropping to audio-only")
                }
            } else {
                imageDiag = "unreadable"
                log.notice("complete.stage1.image — dropped (missing or unreadable) imagePath=\(imagePath, privacy: .public)")
            }
        }

        // --- [stage 2] build messages + options -------------------------------------------------
        let messagesJson = buildMessagesJson(userPrompt: userPrompt, imagePath: safeImagePath)
        let options = #"{"max_tokens":200,"temperature":0.2,"top_p":0.9,"stop":["<end_of_turn>","<|end|>","</s>"]}"#

        // Round-trip: verify the image path survives JSON encoding intact. If it doesn't, we
        // know the bug is Swift-side escaping, not Cactus. If it does, the bug is downstream.
        if let safeImagePath {
            if let parsed = try? JSONSerialization.jsonObject(with: Data(messagesJson.utf8)) as? [[String: Any]],
               let userMsg = parsed.first(where: { ($0["role"] as? String) == "user" }),
               let imgs = userMsg["images"] as? [String],
               let first = imgs.first {
                let match = (first == safeImagePath)
                log.info("complete.stage2.roundtrip — match=\(match) sent=\(safeImagePath, privacy: .public) parsed=\(first, privacy: .public)")
                if !match {
                    log.error("complete.stage2.roundtrip MISMATCH — JSON encoding mutated the path")
                }
            } else {
                log.error("complete.stage2.roundtrip — could not re-parse our own JSON; shape=\(messagesJson, privacy: .public)")
            }
        }

        // --- [stage 3] capture memory + pre-call state ------------------------------------------
        let avail0 = availableMemoryMB()
        let footprint0 = memoryFootprintMB()
        log.info("complete.stage3.pre — availableMB=\(avail0) footprintMB=\(footprint0) pcmBytes=\(pcmData?.count ?? 0) hasImage=\(safeImagePath != nil) promptLen=\(userPrompt.count)")
        log.info("complete.stage3.messages — \(messagesJson, privacy: .public)")

        // --- [stage 4] stream tokens with timing markers ----------------------------------------
        let t0 = Date()
        let firstTokenBox = AtomicDateBox()
        let tokenCounter = AtomicIntBox()

        do {
            try await Task.detached(priority: .userInitiated) { [weak self] in
                _ = try cactusComplete(model, messagesJson, options, nil, { token, _ in
                    firstTokenBox.setIfUnset()
                    tokenCounter.increment()
                    Task { @MainActor in self?.partial.append(token) }
                }, pcmData)
            }.value

            let dt = Date().timeIntervalSince(t0)
            let ttft = firstTokenBox.value.map { $0.timeIntervalSince(t0) }
            let tokens = tokenCounter.value
            let avail1 = availableMemoryMB()
            let footprint1 = memoryFootprintMB()
            log.info("complete.stage4.done — total=\(dt, format: .fixed(precision: 2))s ttft=\(ttft.map { String(format: "%.2f", $0) } ?? "nil")s tokens=\(tokens) peakAvailableMB=\(avail1) footprintMB=\(footprint1)")
        } catch {
            let dt = Date().timeIntervalSince(t0)
            let cactusErr = cactusGetLastError()
            let firstToken = firstTokenBox.value
            let ttft = firstToken.map { $0.timeIntervalSince(t0) }
            let tokens = tokenCounter.value
            let avail1 = availableMemoryMB()
            let footprint1 = memoryFootprintMB()
            let stage = firstToken == nil ? "PREFILL (never produced a token)" : "GENERATION (died after \(tokens) tokens)"
            let detail = "cactus_complete FAILED in \(stage) after \(String(format: "%.2f", dt))s ttft=\(ttft.map { String(format: "%.2f", $0) } ?? "nil") availableMB=\(avail1) footprintMB=\(footprint1) swiftErr=\(error.localizedDescription) cactusErr=\(cactusErr)"
            log.error("complete.stage4.FAILED — \(detail, privacy: .public)")
            partial.append("\n\n[error] \(cactusErr.isEmpty ? error.localizedDescription : cactusErr)\n\n[diag] stage=\(stage) took=\(String(format: "%.2f", dt))s availableMB=\(avail1) footprintMB=\(footprint1)\n[image] \(imageDiag)\n[audio] pcmBytes=\(pcmData?.count ?? 0)")
        }

        isGenerating = false
    }

    deinit {
        if let model { cactusDestroy(model) }
    }

    private func buildMessagesJson(userPrompt: String, imagePath: String? = nil) -> String {
        var userMessage: [String: Any] = ["role": "user", "content": userPrompt]
        if let imagePath { userMessage["images"] = [imagePath] }

        let obj: [[String: Any]] = [
            ["role": "system", "content": "You are a concise, helpful assistant. Answer briefly in plain English."],
            userMessage
        ]
        // `.withoutEscapingSlashes` is critical: Cactus's FFI has a hand-rolled JSON parser that
        // does NOT un-escape `\/` back to `/`. Without this option, `JSONSerialization` writes
        // image paths as `"\/private\/var\/..."`, Cactus `substr`s that literal string, passes
        // it to `std::filesystem::absolute` + `stbi_load`, and prefill dies with
        // `Failed to load image: /\/private\/var\/...`.
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Diagnostics

    /// Enumerates weights on disk and logs counts/sizes. Catches the common failure mode where the
    /// .app bundle is missing files (Xcode copy-resources issue) vs memory issues (bundle is fine).
    private func logWeightsInventory(path: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            log.error("load.stage2.inventory — could not list \(path, privacy: .public)")
            return
        }
        let weightsCount = entries.filter { $0.hasSuffix(".weights") }.count
        let mlpackages = entries.filter { $0.hasSuffix(".mlpackage") }
        let mlmodelcs = entries.filter { $0.hasSuffix(".mlmodelc") }
        let configSize = (try? fm.attributesOfItem(atPath: path + "/config.txt"))?[.size] as? Int ?? -1

        // Sum total bytes across all children — this is the single best signal for "did weights
        // actually ship to the device or did Xcode drop them."
        var totalBytes: Int64 = 0
        if let it = fm.enumerator(atPath: path) {
            for case let name as String in it {
                if let size = (try? fm.attributesOfItem(atPath: path + "/" + name))?[.size] as? Int64 {
                    totalBytes += size
                }
            }
        }
        let totalGB = Double(totalBytes) / 1_073_741_824.0

        log.info("load.stage2.inventory — weightsFiles=\(weightsCount) mlpackage=\(mlpackages, privacy: .public) mlmodelc=\(mlmodelcs, privacy: .public) configBytes=\(configSize) totalGB=\(totalGB, format: .fixed(precision: 2))")
    }

    /// Remaining bytes the app can allocate before iOS issues a memory warning. This is the
    /// number that matters for E4B — if this is <5 GB before init, std::bad_alloc is expected.
    private func availableMemoryMB() -> Int {
        Int(os_proc_available_memory() / (1024 * 1024))
    }

    /// Reads the first bytes of the image file, identifies the format by magic number, and
    /// reports whether stb_image can decode it. Cactus's vision encoder uses stb_image, not
    /// CoreImage, so HEIC is unsupported even though iOS writes it fine.
    private struct ImageProbe {
        let size: Int
        let magicHex: String
        let format: String
        let stbiSupported: Bool
    }
    private func probeImageFile(_ path: String) -> ImageProbe? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 12)
        let attr = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attr?[.size] as? Int) ?? -1
        guard !head.isEmpty else { return nil }
        let hex = head.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        // Magic number sniffing — same set stb_image supports, plus HEIC (rejected).
        let bytes = [UInt8](head)
        let (format, supported): (String, Bool)
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            (format, supported) = ("JPEG", true)
        } else if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            (format, supported) = ("PNG", true)
        } else if bytes.count >= 3, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            (format, supported) = ("GIF", true)
        } else if bytes.count >= 2, bytes[0] == 0x42, bytes[1] == 0x4D {
            (format, supported) = ("BMP", true)
        } else if bytes.count >= 12,
                  bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70,
                  (bytes[8] == 0x68 || bytes[8] == 0x6D) {
            // "ftyp" box with brand starting 'h'(heic/heix) or 'm'(mif1, msf1 used by HEIF).
            (format, supported) = ("HEIC/HEIF", false)
        } else {
            (format, supported) = ("unknown", false)
        }
        return ImageProbe(size: size, magicHex: hex, format: format, stbiSupported: supported)
    }

    /// Current resident memory. mach task_info for phys_footprint.
    private func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }
}

// MARK: - Tiny atomics for the token callback (fires on a worker thread)

private final class AtomicDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date?
    var value: Date? { lock.lock(); defer { lock.unlock() }; return _value }
    func setIfUnset() {
        lock.lock(); defer { lock.unlock() }
        if _value == nil { _value = Date() }
    }
}

private final class AtomicIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
