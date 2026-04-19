import Foundation
import CryptoKit

// MARK: - Gemma (on-device) → structured JSON manual

final class GemmaInstructionService {
    private let engine: CactusEngine
    private let cloudFallback = GeminiCloudTextService()
    init(engine: CactusEngine) { self.engine = engine }

    func generateManual(for query: String, vehicle: String) async throws -> RepairManual {
        let system = """
        You are Otto, an expert auto mechanic. Respond with ONLY a single JSON object. \
        No preamble, no markdown fences, no commentary — just raw JSON.
        """
        let user = """
        Car: \(vehicle)
        Task: \(query)

        Return a JSON object with this exact shape:
        {
          "title": "short repair title (<= 5 words)",
          "steps": [
            { "title": "step title (<= 6 words)",
              "description": "1 to 2 short sentences, <= 140 chars",
              "tools": ["tool name", "tool name"] }
          ]
        }
        Rules:
        - Exactly 3 steps.
        - Each step has 1 or 2 tools. Use common automotive tool names.
        - Keep language simple. No numbering in titles.
        - ONLY return the JSON. No other text.
        """

        // Try on-device Gemma first. The 270M functiongemma model often emits
        // unparseable output — fall back to cloud gemini-2.5-flash with native
        // JSON mode so the demo never dead-ends.
        do {
            let raw = try await engine.complete(systemPrompt: system, userPrompt: user, maxTokens: 800)
            print("[Otto][Gemma] raw output:\n\(raw)")
            if let parsed = Self.parse(raw, query: query, vehicle: vehicle) {
                print("[Otto][Gemma] parsed OK — \(parsed.steps.count) steps")
                return parsed
            }
            print("[Otto][Gemma] parse failed — falling back to Gemini cloud")
        } catch {
            print("[Otto][Gemma] threw: \(error.localizedDescription) — falling back to Gemini cloud")
        }

        let cloud = try await cloudFallback.generateManual(for: query, vehicle: vehicle)
        print("[Otto][Cloud] parsed OK — \(cloud.steps.count) steps")
        return cloud
    }

    static func parse(_ s: String, query: String, vehicle: String) -> RepairManual? {
        var cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```",      with: "")
        }
        guard let first = cleaned.firstIndex(of: "{"),
              let last  = cleaned.lastIndex(of: "}"),
              first < last else { return nil }

        let slice = String(cleaned[first...last])
        guard let data = slice.data(using: .utf8) else { return nil }

        struct Raw: Decodable {
            let title: String
            let steps: [RawStep]
            struct RawStep: Decodable {
                let title: String
                let description: String
                let tools: [String]
            }
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              !raw.steps.isEmpty else { return nil }

        let steps = raw.steps.map {
            RepairStep(title: $0.title, description: $0.description, tools: $0.tools, imagePNGPath: nil)
        }
        return RepairManual(query: query, title: raw.title, vehicle: vehicle, steps: steps)
    }
}

// MARK: - Nanobanana (Gemini 2.5 Flash Image) → PNG per step

final class NanobananaService {
    private let model = "gemini-2.5-flash-image"
    private var endpointURL: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    func generateImage(for step: RepairStep, manualTitle: String, vehicle: String) async throws -> String {
        let prompt = Self.stylePrompt(step: step, manualTitle: manualTitle, vehicle: vehicle)
        // Critical: gemini-2.5-flash-image requires `responseModalities: ["IMAGE"]`
        // in generationConfig or it returns text (or 400).
        let body: [String: Any] = [
            "contents": [[ "parts": [[ "text": prompt ]] ]],
            "generationConfig": [
                "responseModalities": ["IMAGE"]
            ]
        ]

        print("[Otto][Banana] generating step \(step.id.uuidString.prefix(8)): \(step.title)")
        do {
            let data = try await post(body: body, apiKey: Secrets.geminiAPIKey)
            if let png = Self.extractPNG(from: data) {
                return try Self.writeToCache(png, stepId: step.id)
            }
            print("[Otto][Banana] no image in primary response — trying fallback key. Snippet: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        } catch {
            print("[Otto][Banana] primary key threw: \(error.localizedDescription) — retrying with fallback")
        }

        let retry = try await post(body: body, apiKey: Secrets.geminiAPIKeyFallback)
        guard let png2 = Self.extractPNG(from: retry) else {
            let snippet = String(data: retry, encoding: .utf8)?.prefix(240) ?? ""
            throw NSError(
                domain: "Otto.Banana", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no image in Gemini response. \(snippet)"]
            )
        }
        return try Self.writeToCache(png2, stepId: step.id)
    }

    private static func stylePrompt(step: RepairStep, manualTitle: String, vehicle: String) -> String {
        """
        A single isometric technical-blueprint illustration.

        SUBJECT: \(step.title). \(step.description)
        CONTEXT: This step is part of "\(manualTitle)" for a \(vehicle).

        STYLE (strict — match a technical manual diagram):
        • Dark navy background, roughly RGB(36, 43, 60).
        • Line-art wireframe only — thin cream / off-white 1px strokes (RGB 232, 227, 213).
        • No fills, no shading, no gradients. Pure outlines.
        • Orange accent highlights (RGB 234, 138, 60) on the part that is the focus of THIS step, or on the tool being used.
        • A subtle grid floor beneath the object (hairline cream grid on navy).
        • Single focal object, centered, isometric 3/4 perspective.
        • Absolutely NO text, NO labels, NO arrows, NO numbers, NO dimension callouts.
        • Clean, minimal, hand-drafted technical look. No photorealism.
        """
    }

    private func post(body: [String: Any], apiKey: String) async throws -> Data {
        var comps = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw NSError(
                domain: "Otto.Banana", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(snippet)"]
            )
        }
        return data
    }

    private static func extractPNG(from data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }

        for part in parts {
            // Gemini returns either "inlineData" or "inline_data" depending on version.
            let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
            if let b64 = inline?["data"] as? String, let png = Data(base64Encoded: b64) {
                return png
            }
        }
        return nil
    }

    private static func writeToCache(_ png: Data, stepId: UUID) throws -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepairGuideImages", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(stepId.uuidString).png")
        try png.write(to: url)
        return url.path
    }
}

// MARK: - Gemini cloud text fallback (gemini-2.5-flash, JSON mode)
// Runs only when on-device Gemma returns unparseable output. Uses native
// response-schema enforcement so we virtually never parse-fail the cloud path.

final class GeminiCloudTextService {
    private let model = "gemini-2.5-flash"
    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    func generateManual(for query: String, vehicle: String) async throws -> RepairManual {
        let instruction = """
        You are Otto, an expert auto mechanic. A user of a \(vehicle) asks: "\(query)"
        Produce exactly 3 short repair steps. Each description must be 1–2 short sentences,
        <= 140 characters. Each step has 1 or 2 common automotive tools. Do not number titles.
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "steps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title":       ["type": "string"],
                            "description": ["type": "string"],
                            "tools":       ["type": "array", "items": ["type": "string"]]
                        ],
                        "required": ["title", "description", "tools"]
                    ]
                ]
            ],
            "required": ["title", "steps"]
        ]

        let body: [String: Any] = [
            "contents": [["parts": [["text": instruction]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema":   schema,
                "temperature":      0.2
            ]
        ]

        let data = try await post(body: body, apiKey: Secrets.geminiAPIKey)
        guard let root    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands   = root["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts   = content["parts"] as? [[String: Any]],
              let text    = parts.first?["text"] as? String else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw NSError(domain: "Otto.Cloud", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "malformed cloud response. \(snippet)"])
        }
        print("[Otto][Cloud] raw JSON:\n\(text)")

        guard let manual = GemmaInstructionService.parse(text, query: query, vehicle: vehicle) else {
            throw NSError(domain: "Otto.Cloud", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "cloud returned unparseable JSON"])
        }
        return manual
    }

    private func post(body: [String: Any], apiKey: String) async throws -> Data {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw NSError(domain: "Otto.Cloud", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(snippet)"])
        }
        return data
    }
}

// MARK: - On-device cache (JSON manifest + PNGs per step)

final class RepairGuideCache {
    private var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepairGuides", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func key(for query: String) -> String {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func load(for query: String) -> RepairManual? {
        let url = dir.appendingPathComponent("\(key(for: query)).json")
        guard let data = try? Data(contentsOf: url),
              let manual = try? JSONDecoder().decode(RepairManual.self, from: data) else { return nil }
        for step in manual.steps {
            guard let p = step.imagePNGPath,
                  FileManager.default.fileExists(atPath: p) else { return nil }
        }
        return manual
    }

    func save(_ manual: RepairManual) {
        let url = dir.appendingPathComponent("\(key(for: manual.query)).json")
        if let data = try? JSONEncoder().encode(manual) {
            try? data.write(to: url)
        }
    }
}
