import Foundation
import CryptoKit

// Shared lexicon for our blueprint aesthetic — kept in one place so the style
// stays locked across every step (continuity is what makes the manual look
// like one coherent document instead of 8 unrelated illustrations).
enum RepairImageStyle {
    static let locked = """
    BLUEPRINT-STYLE TECHNICAL ILLUSTRATION.
    Dark navy background, approximately RGB(36, 43, 60).
    Thin cream / off-white 1px line art only (RGB 232, 227, 213). No fills, no shading, no gradients.
    Orange accent highlights (RGB 234, 138, 60) ONLY on the focal part of this specific step, or the tool acting on it.
    A subtle hairline cream grid floor beneath the subject, fading toward the edges.
    Clean isometric 3/4 perspective. Hand-drafted technical-manual feel.
    NO text, NO labels, NO arrows, NO numbers, NO dimension callouts, NO photographic realism, NO cartoon.
    """
}

// MARK: - Gemma (on-device) → structured JSON manual

final class GemmaInstructionService {
    private let engine: InferenceController
    private let cloudFallback = GeminiCloudTextService()
    init(engine: InferenceController) { self.engine = engine }

    func generateManual(for query: String, vehicle: String) async throws -> RepairManual {
        let system = """
        You are Otto, an expert automotive technician writing an in-depth illustrated repair guide. \
        Respond with ONLY a single JSON object. No preamble, no markdown fences, no commentary.
        """
        let user = Self.guidePrompt(query: query, vehicle: vehicle)

        // Try on-device Gemma first. The 270M / E2B on-device variants rarely
        // emit this rich a structure cleanly, so the cloud fallback below is
        // the one that almost always ends up rendering the demo.
        do {
            let raw = try await engine.complete(systemPrompt: system, userPrompt: user, maxTokens: 2000)
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

    static func guidePrompt(query: String, vehicle: String) -> String {
        """
        Vehicle: \(vehicle)
        User task: "\(query)"

        Return a SINGLE JSON object with this exact shape:
        {
          "title": "concise guide title, 4–8 words",
          "overview": "1–2 sentence plain-English overview",
          "requiredTools": ["tool 1", "tool 2", "..."],
          "safetyWarnings": ["one concise safety item", "..."],
          "sceneBible": {
            "vehicle": "locked visual description of the vehicle (model, color, wheels)",
            "environment": "locked description of the environment (driveway, garage bay, lighting)",
            "style": "short reminder that every frame is a dark-navy blueprint line-art illustration with orange accents"
          },
          "steps": [
            {
              "title": "imperative step title, 3–6 words",
              "description": "2–4 sentence written instruction that the user will read on-screen",
              "tools": ["specific tools/parts used in THIS step only"],
              "safetyNote": "optional one-sentence caution, or empty string",
              "stateBullets": [
                "world-state bullet that must be visibly true in this step's image",
                "..."
              ],
              "action": "single sentence describing what the focal hand / tool is doing right now",
              "camera": "one of: 'wide establishing shot of the whole vehicle from X angle' OR 'medium shot showing <part> with the surrounding <components> visible for location reference' OR 'extreme close-up of <part> with <adjacent landmarks> clearly visible so the user can locate it' — CHOOSE the framing that best teaches where to operate"
            }
          ]
        }

        Rules:
        - Produce between 6 and 10 steps — be thorough.
        - The FIRST step should use a WIDE establishing framing (locate the area).
        - Operating steps should use MEDIUM or EXTREME CLOSE-UP framings — and the camera description MUST name surrounding components so the user knows exactly where the focal part sits on the car. Do NOT say "close-up of the oil drain plug" — say "extreme close-up of the oil drain plug on the underside of the oil pan, with the front subframe and the engine's lower bolt visible in frame for location reference".
        - stateBullets: 3–5 short bullets each. Things like "hood is OPEN", "front-left wheel is REMOVED", "jack stand is POSITIONED under the pinch weld". Describe the WORLD, not the UI.
        - Do NOT put step numbers inside titles.
        - Output valid JSON only. No markdown, no commentary, no extra fields.
        """
    }

    static func parse(_ s: String, query: String, vehicle: String) -> RepairManual? {
        var cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```",     with: "")
        }
        // Extract the first balanced {...} — nano_banana's trick, in Swift.
        guard let slice = firstJSONObject(in: cleaned),
              let data = slice.data(using: .utf8) else { return nil }

        struct Raw: Decodable {
            let title: String
            let overview: String?
            let requiredTools: [String]?
            let safetyWarnings: [String]?
            let sceneBible: RawScene?
            let steps: [RawStep]

            struct RawScene: Decodable {
                let vehicle: String
                let environment: String
                let style: String
            }
            struct RawStep: Decodable {
                let title: String
                let description: String
                let tools: [String]?
                let safetyNote: String?
                let stateBullets: [String]?
                let action: String?
                let camera: String?
            }
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              !raw.steps.isEmpty else { return nil }

        let steps = raw.steps.map { r in
            RepairStep(
                title: r.title,
                description: r.description,
                tools: r.tools ?? [],
                safetyNote: (r.safetyNote?.isEmpty == false) ? r.safetyNote : nil,
                stateBullets: r.stateBullets,
                action: r.action,
                camera: r.camera,
                imagePNGPath: nil
            )
        }
        let scene = raw.sceneBible.map {
            SceneBible(vehicle: $0.vehicle, environment: $0.environment, style: $0.style)
        }
        return RepairManual(
            query: query,
            title: raw.title,
            vehicle: vehicle,
            overview: raw.overview,
            requiredTools: raw.requiredTools ?? [],
            safetyWarnings: raw.safetyWarnings ?? [],
            sceneBible: scene,
            steps: steps
        )
    }

    /// Return the first balanced {...} substring (handles strings/escapes).
    private static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escape = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escape { escape = false }
                else if ch == "\\" { escape = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" {
                    if depth == 0 { start = i }
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0, let s = start {
                        return String(text[s...i])
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

// MARK: - Nanobanana (Gemini 2.5 Flash Image) → PNG per step

final class NanobananaService {
    private let model = "gemini-2.5-flash-image"
    private var endpointURL: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    func generateImage(for step: RepairStep, manual: RepairManual) async throws -> String {
        let prompt = Self.buildPrompt(step: step, manual: manual)
        // Critical: gemini-2.5-flash-image requires `responseModalities: ["IMAGE"]`.
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

    /// Scene-bible-driven prompt. Locked vehicle/environment/style blocks give
    /// continuity across steps; stateBullets + action + camera drive THIS frame.
    /// Close-up cameras explicitly instruct the model to include surrounding
    /// components so the user always sees WHERE on the car to operate.
    private static func buildPrompt(step: RepairStep, manual: RepairManual) -> String {
        let vehicle     = manual.sceneBible?.vehicle     ?? manual.vehicle
        let environment = manual.sceneBible?.environment ?? "clean workshop bay with neutral lighting"

        let camera = step.camera ?? "medium shot showing the focal part with the surrounding vehicle area clearly visible so the user can locate it"
        let action = step.action ?? step.description

        let stateBlock: String
        if let bullets = step.stateBullets, !bullets.isEmpty {
            stateBlock = bullets.map { "- \($0)" }.joined(separator: "\n")
        } else {
            stateBlock = "- The vehicle is in the same state the previous step left it in."
        }

        let tools = step.tools.isEmpty ? "none in this specific shot" : step.tools.joined(separator: ", ")

        return """
        \(RepairImageStyle.locked)

        VEHICLE (locked, must match previous frames):
        \(vehicle)

        ENVIRONMENT (locked, must match previous frames):
        \(environment)

        TOOLS VISIBLE IN THIS FRAME:
        \(tools)

        CURRENT WORLD STATE — every bullet MUST be visibly true in the generated image:
        \(stateBlock)

        WHAT IS HAPPENING RIGHT NOW:
        \(action)

        CAMERA AND FRAMING:
        \(camera)

        LOCATION CLARITY RULE:
        If the camera framing is a close-up, the surrounding components named in the camera brief MUST be clearly visible in the frame so the user can locate the focal part on the car. Do not isolate the part against empty space — always show enough context that someone could find it on their own vehicle.

        FOCAL HIGHLIGHT:
        The part or area that this step OPERATES ON is rendered in the orange accent color (RGB 234, 138, 60). Everything else stays cream line-art on navy.

        Absolute rules:
        - Blueprint line-art style only. No photorealism, no cartoon, no shading.
        - No text, captions, arrows, numerals, or UI overlays.
        - The world-state bullets above are not optional — each must be visibly true.
        """
    }

    private func post(body: [String: Any], apiKey: String) async throws -> Data {
        var comps = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

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
//
// HTTP plumbing + primary/fallback key retry live in GeminiCloudChatService;
// this class stays as the thin repair-specific wrapper that defines the
// schema and parses the returned JSON into a RepairManual.

final class GeminiCloudTextService {
    private let cloud = GeminiCloudChatService()

    func generateManual(for query: String, vehicle: String) async throws -> RepairManual {
        // Same rich prompt as the on-device path, plus a responseSchema so we
        // virtually always get clean JSON back.
        let instruction = GemmaInstructionService.guidePrompt(query: query, vehicle: vehicle)

        let stepItem: [String: Any] = [
            "type": "object",
            "properties": [
                "title":        ["type": "string"],
                "description":  ["type": "string"],
                "tools":        ["type": "array", "items": ["type": "string"]],
                "safetyNote":   ["type": "string"],
                "stateBullets": ["type": "array", "items": ["type": "string"]],
                "action":       ["type": "string"],
                "camera":       ["type": "string"]
            ],
            "required": ["title", "description", "tools", "stateBullets", "action", "camera"]
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title":          ["type": "string"],
                "overview":       ["type": "string"],
                "requiredTools":  ["type": "array", "items": ["type": "string"]],
                "safetyWarnings": ["type": "array", "items": ["type": "string"]],
                "sceneBible": [
                    "type": "object",
                    "properties": [
                        "vehicle":     ["type": "string"],
                        "environment": ["type": "string"],
                        "style":       ["type": "string"]
                    ],
                    "required": ["vehicle", "environment", "style"]
                ],
                "steps": ["type": "array", "items": stepItem]
            ],
            "required": ["title", "overview", "requiredTools", "safetyWarnings", "sceneBible", "steps"]
        ]

        let text = try await cloud.structured(instruction: instruction, schema: schema, temperature: 0.3)
        print("[Otto][Cloud] raw JSON:\n\(text)")

        guard let manual = GemmaInstructionService.parse(text, query: query, vehicle: vehicle) else {
            throw NSError(domain: "Otto.Cloud", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "cloud returned unparseable JSON"])
        }
        return manual
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
