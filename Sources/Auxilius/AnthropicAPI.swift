import Foundation

/// The two Claude API calls the app makes share their headers and error handling here.
enum AnthropicAPI {
    private static let baseURL = URL(string: "https://api.anthropic.com/v1/")!
    private static let version = "2023-06-01"
    private static let timeout: TimeInterval = 120

    static func request(_ path: String, apiKey: String, beta: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        if let beta {
            request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A gateway error can come back as HTML; the status code still reports it.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "No details."
            throw APIError.status(status, message: message)
        }
        return json
    }
}

enum APIError: LocalizedError {
    case status(Int, message: String)
    case refused

    var errorDescription: String? {
        switch self {
        case .status(401, _): "Anthropic rejected the API key."
        case .status(let status, let message): "Claude returned \(status): \(message)"
        case .refused: "Claude declined to read this page."
        }
    }
}
