import Foundation

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
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
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

        let (data, response) = try await session.data(for: request)
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

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let polishedText = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !polishedText.isEmpty else {
            throw OpenAIClientError.emptyPolishResponse
        }

        return polishedText
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
