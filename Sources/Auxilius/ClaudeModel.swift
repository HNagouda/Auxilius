import Foundation

/// A model the transcription can run on, as the Models API describes it.
struct ClaudeModel: Codable, Hashable, Identifiable {
    // Models documented to accept `fallbacks: "default"`; sending it to any other model is a 400.
    private static let serverFallbackModels: Set = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    private static let pageSize = 100
    // The smallest output limit any Claude model has had, for entries that leave max_tokens out.
    private static let minimumOutputTokens = 4096

    static let standard = ClaudeModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", maxOutputTokens: 128_000, supportsLowEffort: true)

    let id: String
    let displayName: String
    let maxOutputTokens: Int
    // Older models such as Claude Haiku 4.5 reject the effort setting outright.
    let supportsLowEffort: Bool

    var supportsServerFallback: Bool { Self.serverFallbackModels.contains(id) }

    // The same model by id, so a saved choice still matches the list after the API updates its limits.
    static func == (lhs: ClaudeModel, rhs: ClaudeModel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Every model on the account that can read an image, newest first, as the API orders them.
    static func available(apiKey: String) async throws -> [ClaudeModel] {
        var models: [ClaudeModel] = []
        var afterID: String?
        repeat {
            var path = "models?limit=\(pageSize)"
            if let afterID {
                path += "&after_id=\(afterID)"
            }
            let page = try await AnthropicAPI.send(AnthropicAPI.request(path, apiKey: apiKey))
            for entry in page["data"] as? [[String: Any]] ?? [] {
                if let model = ClaudeModel(entry) {
                    models.append(model)
                }
            }
            afterID = page["has_more"] as? Bool == true ? page["last_id"] as? String : nil
        } while afterID != nil

        return models
    }

    init(id: String, displayName: String, maxOutputTokens: Int, supportsLowEffort: Bool) {
        self.id = id
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
        self.supportsLowEffort = supportsLowEffort
    }

    /// Nil for entries that cannot take an image, since a page photo is the whole input.
    private init?(_ entry: [String: Any]) {
        guard let id = entry["id"] as? String else { return nil }

        let capabilities = entry["capabilities"] as? [String: Any] ?? [:]
        guard Self.isSupported(capabilities["image_input"]) else { return nil }

        let effort = capabilities["effort"] as? [String: Any]
        self.init(
            id: id,
            displayName: entry["display_name"] as? String ?? id,
            maxOutputTokens: entry["max_tokens"] as? Int ?? Self.minimumOutputTokens,
            supportsLowEffort: Self.isSupported(effort) && Self.isSupported(effort?["low"])
        )
    }

    private static func isSupported(_ capability: Any?) -> Bool {
        (capability as? [String: Any])?["supported"] as? Bool == true
    }
}
