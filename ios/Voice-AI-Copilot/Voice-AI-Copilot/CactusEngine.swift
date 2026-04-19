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
        var safeImagePath: String? = nil
        if let imagePath {
            if FileManager.default.fileExists(atPath: imagePath) {
                safeImagePath = imagePath
            } else {
                log.notice("complete.stage1.image — dropped missing imagePath=\(imagePath, privacy: .public)")
            }
        }

        // --- [stage 2] build messages + options -------------------------------------------------
        let messagesJson = buildMessagesJson(userPrompt: userPrompt, imagePath: safeImagePath)
        let options = #"{"max_tokens":200,"temperature":0.2,"top_p":0.9,"stop":["<end_of_turn>","<|end|>","</s>"]}"#

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
            partial.append("\n\n[error] \(cactusErr.isEmpty ? error.localizedDescription : cactusErr)\n\n[diag] stage=\(stage) took=\(String(format: "%.2f", dt))s availableMB=\(avail1) footprintMB=\(footprint1)")
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
        let data = try! JSONSerialization.data(withJSONObject: obj)
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
