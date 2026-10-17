import Foundation

/// Every page the app has captured, kept on disk while the Settings toggle is on.
/// Each page is a JPEG plus a JSON file with the model's transcript, so the pair can serve as a
/// test set for comparing other models, local ones included, against what the API model wrote.
enum PageHistory {
    static let directory = Feed.directory.appendingPathComponent("History", isDirectory: true)
    // About 300 KB a page, so the history stays under roughly 300 MB.
    private static let limit = 1000

    struct Entry: Codable {
        var capturedAt: Date
        var model: String?
        // The model's own Markdown, circuit and sketch blocks included.
        var transcript: String?
    }

    /// Saves a new page and returns the name its files share, such as '2026-10-17T13-12-34.512Z'.
    static func save(jpeg: Data, capturedAt: Date) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileName(for: capturedAt)
        try jpeg.write(to: directory.appendingPathComponent("\(name).jpg"), options: .atomic)
        try write(Entry(capturedAt: capturedAt), named: name)
        try prune()
        return name
    }

    static func saveTranscript(_ transcript: String, model: String, forPageNamed name: String) throws {
        let url = directory.appendingPathComponent("\(name).json")
        // The page may have been pruned or deleted by hand while it was being read.
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entry = try decoder.decode(Entry.self, from: Data(contentsOf: url))
        entry.model = model
        entry.transcript = transcript
        try write(entry, named: name)
    }

    private static func write(_ entry: Entry, named name: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }

    /// Drops the oldest pages beyond the limit. Names sort by time, so the oldest come first.
    private static func prune() throws {
        let images = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
        for image in images.dropLast(limit) {
            let name = String(image.dropLast(".jpg".count))
            let record = directory.appendingPathComponent("\(name).json")
            try FileManager.default.removeItem(at: directory.appendingPathComponent(image))
            if FileManager.default.fileExists(atPath: record.path) {
                try FileManager.default.removeItem(at: record)
            }
        }
    }

    // Colons are not allowed in Finder file names, so the time uses dashes.
    private static func fileName(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
