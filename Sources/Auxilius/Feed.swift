import Foundation

/// What the MCP server reads: the latest page as a JPEG next to a small JSON record.
/// The app writes both; the MCP server runs as a separate process and only reads them.
struct PageRecord: Codable {
    var capturedAt: Date
    var transcript: String
    // False while the transcript still describes an earlier version of the page.
    var transcriptIsCurrent: Bool
}

enum Feed {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Auxilius", isDirectory: true)
    static let imageURL = directory.appendingPathComponent("page.jpg")
    static let recordURL = directory.appendingPathComponent("page.json")

    static func write(jpeg: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: imageURL, options: .atomic)
    }

    static func write(_ record: PageRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    static func read() throws -> (record: PageRecord, jpeg: Data)? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(PageRecord.self, from: Data(contentsOf: recordURL))
        return (record, try Data(contentsOf: imageURL))
    }
}
