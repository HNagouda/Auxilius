import Foundation

/// Registers this app's MCP server with the chat clients that can launch local servers.
enum ChatConnections {
    private static let serverName = "auxilius"
    private static let claudeDesktopConfig = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude/claude_desktop_config.json")

    // Shared by the ChatGPT desktop app's Codex mode, the Codex CLI and its IDE extension.
    private static let codexConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")

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

extension ChatConnections {
    /// Writes an [mcp_servers.auxilius] table into the Codex config, replacing an earlier one
    /// so a moved app is picked up, and leaving every other line as it was.
    static func addToCodex() throws {
        try addServer(toCodexConfigAt: codexConfig)
    }

    static func addServer(toCodexConfigAt url: URL) throws {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        let existing = exists ? try String(contentsOf: url, encoding: .utf8) : ""
        // The config can hold API keys, so the rewrite and the backup keep its permissions (often 600).
        let permissions = exists ? try manager.attributesOfItem(atPath: url.path)[.posixPermissions] : nil
        if exists {
            let backup = url.appendingPathExtension("auxilius-backup")
            try existing.write(to: backup, atomically: true, encoding: .utf8)
            try setPermissions(permissions, of: backup)
        }

        var lines = withoutAuxiliusTable(existing.components(separatedBy: "\n"))
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        if !lines.isEmpty {
            lines.append("")
        }
        lines += ["[mcp_servers.\(serverName)]", "command = \"\(executablePath)\"", "args = [\"--mcp\"]", ""]

        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try setPermissions(permissions, of: url)
    }

    private static func setPermissions(_ permissions: Any?, of url: URL) throws {
        guard let permissions else { return }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Drops the auxilius table and its keys, up to the next table header.
    private static func withoutAuxiliusTable(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var isInsideTable = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                isInsideTable = trimmed == "[mcp_servers.\(serverName)]"
            }
            if !isInsideTable {
                kept.append(line)
            }
        }
        return kept
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
