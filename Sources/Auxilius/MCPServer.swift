import AppKit
import Foundation

/// A Model Context Protocol server over stdio, so a chat client can look at the page.
/// Messages are newline-delimited JSON-RPC 2.0. It serves one tool and reads what the app wrote to the Feed.
enum MCPServer {
    private static let toolName = "read_paper"
    private static let fallbackProtocolVersion = "2025-06-18"
    private static let parseError = -32700
    private static let methodNotFound = -32601
    private static let invalidParams = -32602

    private static let instructions = """
        Auxilius watches the sheet of paper the user is writing on through their desk camera. \
        When the user mentions their working, their paper, their notebook or what they wrote, \
        call read_paper instead of asking them to type it out.
        """

    private static let tool: [String: Any] = [
        "name": toolName,
        "title": "Read paper",
        "description": """
            See the page the user is writing on right now: a photo of the page from their desk camera \
            and a transcription of the handwriting as Markdown, with maths in LaTeX and diagrams as Mermaid. Use it whenever the user refers \
            to their working, their paper or what they have written. The photo is the ground truth; \
            the transcription can lag a few seconds behind it.
            """,
        "inputSchema": ["type": "object", "properties": [String: Any]()],
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ]

    static func run() -> Never {
        while let line = readLine() {
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                send(error(id: NSNull(), code: parseError, message: "Not a JSON object: \(line.prefix(200))"))
                continue
            }
            // Notifications carry no id and get no reply.
            guard let id = message["id"] else { continue }

            send(reply(to: message["method"] as? String ?? "", params: message["params"] as? [String: Any] ?? [:], id: id))
        }
        exit(0)
    }

    private static func reply(to method: String, params: [String: Any], id: Any) -> [String: Any] {
        switch method {
        case "initialize":
            let result: [String: Any] = [
                // Only plain tools are served, which every protocol version supports, so the client's version is fine.
                "protocolVersion": params["protocolVersion"] as? String ?? fallbackProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "auxilius", "title": "Auxilius", "version": appVersion],
                "instructions": instructions,
            ]
            return ["jsonrpc": "2.0", "id": id, "result": result]
        case "ping":
            return ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
        case "tools/list":
            return ["jsonrpc": "2.0", "id": id, "result": ["tools": [tool]]]
        case "tools/call" where params["name"] as? String == toolName:
            return ["jsonrpc": "2.0", "id": id, "result": readPaper()]
        case "tools/call":
            return error(id: id, code: invalidParams, message: "Unknown tool: \(params["name"] ?? "none")")
        default:
            return error(id: id, code: methodNotFound, message: "Method not found: \(method)")
        }
    }

    private static func readPaper() -> [String: Any] {
        let page: (record: PageRecord, jpeg: Data)?
        do {
            page = try Feed.read()
        } catch {
            return toolError("Auxilius could not read its latest page: \(error.localizedDescription)")
        }
        guard let page else {
            return toolError(isAppRunning
                ? "Auxilius is open but has not seen a page yet. Ask the user to put their paper under the desk camera."
                : "Auxilius is not open. Ask the user to open it and put their paper under the desk camera.")
        }

        return ["content": [
            ["type": "text", "text": summary(of: page.record)],
            ["type": "image", "data": page.jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
        ]]
    }

    private static func summary(of record: PageRecord) -> String {
        let age = RelativeDateTimeFormatter().localizedString(for: record.capturedAt, relativeTo: Date())
        var lines = ["Page photographed \(age)."]
        if !isAppRunning {
            lines.append("Auxilius has since been closed, so the page may have changed.")
        }
        if record.transcript.isEmpty {
            lines.append("No transcription yet. Read the photo.")
        } else {
            if !record.transcriptIsCurrent {
                lines.append("The transcription is of an earlier moment; the photo is newer.")
            }
            lines.append("Transcription:\n\n\(record.transcript)")
        }
        return lines.joined(separator: "\n")
    }

    private static var isAppRunning: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .isEmpty
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func toolError(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func send(_ message: [String: Any]) {
        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        } catch {
            // stdout belongs to the protocol, so problems go to stderr, which clients log.
            FileHandle.standardError.write(Data("auxilius: could not encode reply: \(error)\n".utf8))
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
