import Foundation

// Generic gemini-2.5-flash client. Two entry points:
//
// • answer(userPrompt:)        — free-form spoken reply, used by the voice
//                                 chat timeout fallback in OttoStore.
// • structured(instruction:, schema:)
//                              — schema-enforced JSON text, used by the
//                                 repair-guide cloud reroute in
//                                 GeminiCloudTextService.generateManual.
//
// Consolidating the HTTP plumbing + primary/fallback key retry here means
// any gemini-2.5-flash consumer in the app gets consistent timeouts, error
// handling, and retry semantics. If you add a third use case, add another
// wrapper method here rather than spinning up a new service.
final class GeminiCloudChatService {
    private let model = "gemini-2.5-flash"
    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    // Otto persona primer — baked in so the cloud answer doesn't read like a
    // different assistant when we reroute mid-demo.
    private static let ottoPersona = """
    You are Otto, a friendly expert auto mechanic helping a driver with their vehicle. \
    Answer in one or two short spoken sentences — conversational, confident, no lists or headings. \
    If the question isn't car-related, answer briefly and steer back to cars.
    """

    // MARK: - Free-form chat

    func answer(userPrompt: String, timeout: TimeInterval = 20) async throws -> String {
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": Self.ottoPersona]]
            ],
            "contents": [[
                "role": "user",
                "parts": [["text": userPrompt]]
            ]],
            "generationConfig": [
                "temperature": 0.6,
                "maxOutputTokens": 200
            ]
        ]
        let data = try await postWithRetry(body: body, timeout: timeout)
        guard let text = Self.extractText(from: data), !text.isEmpty else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw NSError(domain: "Otto.Cloud", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "empty/malformed cloud chat response. \(snippet)"])
        }
        return text
    }

    // MARK: - Schema-enforced structured output

    /// Returns the raw JSON text emitted by gemini-2.5-flash under a
    /// responseSchema. Callers parse it into whatever domain type they need.
    func structured(instruction: String,
                    schema: [String: Any],
                    temperature: Double = 0.3,
                    timeout: TimeInterval = 45) async throws -> String {
        let body: [String: Any] = [
            "contents": [["parts": [["text": instruction]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema":   schema,
                "temperature":      temperature
            ]
        ]
        let data = try await postWithRetry(body: body, timeout: timeout)
        guard let text = Self.extractText(from: data), !text.isEmpty else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw NSError(domain: "Otto.Cloud", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "malformed cloud structured response. \(snippet)"])
        }
        return text
    }

    // MARK: - HTTP plumbing

    // Primary key first; on throw, retry with the fallback key so one
    // rate-limited key doesn't break the demo. Matches the pattern in
    // NanobananaService.
    private func postWithRetry(body: [String: Any], timeout: TimeInterval) async throws -> Data {
        do {
            return try await post(body: body, apiKey: Secrets.geminiAPIKey, timeout: timeout)
        } catch {
            print("[Otto][Cloud] primary key threw: \(error.localizedDescription) — retrying with fallback")
            return try await post(body: body, apiKey: Secrets.geminiAPIKeyFallback, timeout: timeout)
        }
    }

    private func post(body: [String: Any], apiKey: String, timeout: TimeInterval) async throws -> Data {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw NSError(domain: "Otto.Cloud", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(snippet)"])
        }
        return data
    }

    private static func extractText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let pieces = parts.compactMap { $0["text"] as? String }
        let joined = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
