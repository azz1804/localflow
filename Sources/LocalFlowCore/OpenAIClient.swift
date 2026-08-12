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
    case emptyPromptResponse
    case audioFileUnavailable
    case audioFileEmpty
    case audioFileTooLarge(actualBytes: Int64, maximumBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is missing. Add it to .env."
        case .invalidURL:
            return "The OpenAI API URL could not be created."
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case let .badStatus(statusCode, body):
            return "OpenAI request failed (HTTP \(statusCode)): \(Self.apiMessage(from: body))"
        case .emptyTranscription:
            return "OpenAI returned an empty transcription."
        case .emptyPolishResponse:
            return "OpenAI returned an empty polish response."
        case .emptyPromptResponse:
            return "OpenAI returned an empty Prompt Mode response."
        case .audioFileUnavailable:
            return "The audio recording is no longer available."
        case .audioFileEmpty:
            return "The audio recording is empty."
        case let .audioFileTooLarge(actualBytes, maximumBytes):
            return "The audio recording is too large to upload (\(actualBytes) bytes; maximum \(maximumBytes) bytes)."
        }
    }

    private static func apiMessage(from body: String) -> String {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable {
                var message: String
            }
            var error: APIError
        }

        if let data = body.data(using: .utf8),
           let message = try? JSONDecoder().decode(
                ErrorEnvelope.self,
                from: data
           ).error.message.trimmingCharacters(
                in: .whitespacesAndNewlines
           ),
           !message.isEmpty {
            return message
        }
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "No error details were returned." : normalized
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
        try Task.checkCancellation()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIClientError.missingAPIKey
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw OpenAIClientError.invalidURL
        }

        let audioByteCount = try validatedAudioByteCount(fileURL)
        guard audioByteCount <= Self.maximumAudioUploadByteCount else {
            throw OpenAIClientError.audioFileTooLarge(
                actualBytes: audioByteCount,
                maximumBytes: Self.maximumAudioUploadByteCount
            )
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
        let finalizedMultipart = multipart
        let multipartContentType = finalizedMultipart.contentType
        let multipartContentLength = try finalizedMultipart.contentLength()

        let multipartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-multipart-\(UUID().uuidString)")
            .appendingPathExtension("body")
        defer { try? FileManager.default.removeItem(at: multipartURL) }

        let encodingTask = Task.detached(priority: .utility) {
            try finalizedMultipart.write(to: multipartURL)
        }
        try await withTaskCancellationHandler {
            try await encodingTask.value
        } onCancel: {
            encodingTask.cancel()
        }
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.transcriptionRequestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(multipartContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            String(multipartContentLength),
            forHTTPHeaderField: "Content-Length"
        )

        let (data, response) = try await send(
            request,
            uploadFileURL: multipartURL
        )
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenAIClientError.emptyTranscription
        }

        return text
    }

    public func polish(text: String, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        try Task.checkCancellation()
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
        request.timeoutInterval = Self.polishRequestTimeout
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

    public func rewriteAsPrompt(
        text: String,
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        try Task.checkCancellation()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIClientError.missingAPIKey
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIClientError.emptyTranscription
        }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw OpenAIClientError.invalidURL
        }

        let payload = PromptModeResponseRequest(
            model: model,
            instructions: systemPrompt,
            input: userPrompt,
            reasoning: .init(effort: "none"),
            text: .init(verbosity: "medium"),
            maxOutputTokens: 4_096,
            store: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.promptModeRequestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await send(request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(
            PromptModeResponse.self,
            from: data
        )
        let prompt = decoded.output
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw OpenAIClientError.emptyPromptResponse
        }
        return prompt
    }

    private func send(
        _ request: URLRequest,
        uploadFileURL: URL? = nil
    ) async throws -> (Data, URLResponse) {
        for attempt in 1...retryPolicy.maxAttempts {
            try Task.checkCancellation()
            let result: (Data, URLResponse)

            do {
                if let uploadFileURL {
                    result = try await session.upload(
                        for: request,
                        fromFile: uploadFileURL
                    )
                } else {
                    result = try await session.data(for: request)
                }
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
            let bodyData = data.prefix(Self.maximumErrorBodyByteCount)
            let body = String(data: bodyData, encoding: .utf8)
                ?? "<non-UTF8 body>"
            throw OpenAIClientError.badStatus(httpResponse.statusCode, body)
        }
    }

    private func validatedAudioByteCount(_ fileURL: URL) throws -> Int64 {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
        } catch {
            throw OpenAIClientError.audioFileUnavailable
        }
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw OpenAIClientError.audioFileUnavailable
        }
        guard fileSize > 0 else {
            throw OpenAIClientError.audioFileEmpty
        }
        return Int64(fileSize)
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

    private static let maximumAudioUploadByteCount: Int64 = 25 * 1_024 * 1_024
    private static let transcriptionRequestTimeout: TimeInterval = 90
    private static let polishRequestTimeout: TimeInterval = 45
    private static let promptModeRequestTimeout: TimeInterval = 30
    private static let maximumErrorBodyByteCount = 8 * 1_024
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

private struct PromptModeResponseRequest: Encodable {
    struct Reasoning: Encodable {
        var effort: String
    }

    struct TextOptions: Encodable {
        var verbosity: String
    }

    var model: String
    var instructions: String
    var input: String
    var reasoning: Reasoning
    var text: TextOptions
    var maxOutputTokens: Int
    var store: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case reasoning
        case text
        case maxOutputTokens = "max_output_tokens"
        case store
    }
}

private struct PromptModeResponse: Decodable {
    struct OutputItem: Decodable {
        var content: [Content]?
    }

    struct Content: Decodable {
        var type: String
        var text: String?
    }

    var output: [OutputItem]
}
