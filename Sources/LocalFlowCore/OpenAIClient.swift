import Foundation

public struct OpenAIRetryPolicy: Sendable {
    public static let `default` = OpenAIRetryPolicy()

    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.2,
        maximumDelay: TimeInterval = 1
    ) {
        let safeMaximumDelay = maximumDelay.isFinite ? maximumDelay : 1
        let safeInitialDelay = initialDelay.isFinite ? initialDelay : 0.2

        self.maxAttempts = min(max(maxAttempts, 1), 5)
        self.maximumDelay = min(max(safeMaximumDelay, 0), 10)
        self.initialDelay = min(max(safeInitialDelay, 0), self.maximumDelay)
    }
}

public enum OpenAIClientError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case badStatus(Int, String)
    case emptyTranscription
    case emptyPolishResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is missing. Add it to .env."
        case .invalidURL:
            return "The OpenAI API URL could not be created."
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case let .badStatus(statusCode, body):
            return "OpenAI request failed with HTTP \(statusCode): \(body)"
        case .emptyTranscription:
            return "OpenAI returned an empty transcription."
        case .emptyPolishResponse:
            return "OpenAI returned an empty polish response."
        }
    }
}

public final class OpenAIClient: @unchecked Sendable {
    private typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let apiKey: String
    private let session: URLSession
    private let retryPolicy: OpenAIRetryPolicy
    private let sleeper: Sleeper

    public init(
        apiKey: String,
        session: URLSession = .shared,
        retryPolicy: OpenAIRetryPolicy = .default
    ) {
        self.apiKey = apiKey
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleeper = { delay in
            guard delay > 0 else {
                return
            }

            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    init(
        apiKey: String,
        session: URLSession,
        retryPolicy: OpenAIRetryPolicy,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.apiKey = apiKey
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
    }

    public func transcribeAudio(
        fileURL: URL,
        model: String,
        language: String,
        prompt: String
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIClientError.missingAPIKey
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw OpenAIClientError.invalidURL
        }

        var multipart = MultipartFormData()
        multipart.appendField(name: "model", value: model)

        if !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            multipart.appendField(name: "language", value: language)
        }

        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            multipart.appendField(name: "prompt", value: prompt)
        }

        try multipart.appendFile(
            name: "file",
            fileURL: fileURL,
            filename: fileURL.lastPathComponent,
            mimeType: mimeType(for: fileURL)
        )
        multipart.finalize()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.data

        let (data, response) = try await send(request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenAIClientError.emptyTranscription
        }

        return text
    }

    public func polish(text: String, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIClientError.missingAPIKey
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenAIClientError.invalidURL
        }

        let payload = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt)
            ],
            temperature: 0.2
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await send(request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let polishedText = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !polishedText.isEmpty else {
            throw OpenAIClientError.emptyPolishResponse
        }

        return polishedText
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 1...retryPolicy.maxAttempts {
            let result: (Data, URLResponse)

            do {
                result = try await session.data(for: request)
            } catch {
                guard attempt < retryPolicy.maxAttempts, isRetryableNetworkError(error) else {
                    throw error
                }

                try await sleeper(retryDelay(afterFailedAttempt: attempt, response: nil))
                continue
            }

            if
                attempt < retryPolicy.maxAttempts,
                let httpResponse = result.1 as? HTTPURLResponse,
                isRetryableHTTPStatus(httpResponse.statusCode)
            {
                try await sleeper(retryDelay(afterFailedAttempt: attempt, response: httpResponse))
                continue
            }

            return result
        }

        // maxAttempts is clamped to at least one, so execution cannot reach this point.
        throw OpenAIClientError.invalidResponse
    }

    private func retryDelay(afterFailedAttempt attempt: Int, response: HTTPURLResponse?) -> TimeInterval {
        let exponentialDelay = min(
            retryPolicy.initialDelay * pow(2, Double(attempt - 1)),
            retryPolicy.maximumDelay
        )

        guard
            let retryAfterValue = response?.value(forHTTPHeaderField: "Retry-After"),
            let retryAfterDelay = TimeInterval(retryAfterValue),
            retryAfterDelay >= 0
        else {
            return exponentialDelay
        }

        return min(max(exponentialDelay, retryAfterDelay), retryPolicy.maximumDelay)
    }

    private func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 429 || [500, 502, 503, 504].contains(statusCode)
    }

    private func isRetryableNetworkError(_ error: Error) -> Bool {
        guard !Task.isCancelled else {
            return false
        }

        let error = error as NSError
        guard error.domain == NSURLErrorDomain else {
            return false
        }

        switch URLError.Code(rawValue: error.code) {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .cannotLoadFromNetwork,
             .secureConnectionFailed,
             .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            throw OpenAIClientError.badStatus(httpResponse.statusCode, body)
        }
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        default:
            return "application/octet-stream"
        }
    }
}

private struct TranscriptionResponse: Decodable {
    var text: String
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: ChatMessage
    }
}
