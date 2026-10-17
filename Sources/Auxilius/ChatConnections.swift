import Foundation

/// Registers this app's MCP server with the chat clients that can launch local servers.
enum ChatConnections {
    private static let serverName = "auxilius"
    private static let claudeDesktopConfig = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude/claude_desktop_config.json")

    static var executablePath: String {
        Bundle.main.executablePath ?? ""
    }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user \(serverName) -- '\(executablePath)' --mcp"
    }

    /// False when the app runs from a build folder, where the registered path breaks as soon as the app moves.
    static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
    }

    /// Adds or updates the "auxilius" entry and leaves every other setting as it was.
    static func addToClaudeDesktop() throws {
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: claudeDesktopConfig.path) {
            let data = try Data(contentsOf: claudeDesktopConfig)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChatConnectionError.unreadableConfig(claudeDesktopConfig.path)
            }
            config = existing
            try data.write(to: claudeDesktopConfig.appendingPathExtension("auxilius-backup"), options: .atomic)
        }

        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": executablePath, "args": ["--mcp"]]
        config["mcpServers"] = servers

        try FileManager.default.createDirectory(at: claudeDesktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: claudeDesktopConfig, options: .atomic)
    }
}

enum ChatConnectionError: LocalizedError {
    case unreadableConfig(String)

    var errorDescription: String? {
        switch self {
        case .unreadableConfig(let path): "\(path) is not a JSON object, so Auxilius left it alone."
        }
    }
}
