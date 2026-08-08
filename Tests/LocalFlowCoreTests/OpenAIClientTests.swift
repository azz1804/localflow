import Foundation
import XCTest
@testable import LocalFlowCore

final class OpenAIClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.install(nil)
        super.tearDown()
    }

    func testPromptModeUsesResponsesAPILowLatencyPayload() async throws {
        let script = ResponseScript([
            .http(
                status: 200,
                body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"Objectif : corriger le bug.\n\nContraintes : préserver les tests."}]}]}"#,
                headers: [:]
            )
        ])
        URLProtocolStub.install(script)
        let client = makeClient(delays: DelayRecorder())

        let result = try await client.rewriteAsPrompt(
            text: "corrige le bug et garde les tests",
            model: "gpt-5.6-luna",
            systemPrompt: "Réécris en prompt.",
            userPrompt: "<dictation>corrige le bug</dictation>"
        )

        XCTAssertEqual(
            result,
            "Objectif : corriger le bug.\n\nContraintes : préserver les tests."
        )
        let request = try XCTUnwrap(script.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.timeoutInterval, 30)
        let body = try requestBody(request)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 4_096)
        XCTAssertEqual(
            (payload["reasoning"] as? [String: Any])?["effort"]
                as? String,
            "none"
        )
        XCTAssertEqual(
            (payload["text"] as? [String: Any])?["verbosity"]
                as? String,
            "low"
        )
    }

    func testPromptModeRejectsEmptyModelOutput() async throws {
        let script = ResponseScript([
            .http(
                status: 200,
                body: #"{"output":[{"type":"reasoning"}]}"#,
                headers: [:]
            )
        ])
        URLProtocolStub.install(script)
        let client = makeClient(delays: DelayRecorder())

        do {
            _ = try await client.rewriteAsPrompt(
                text: "une demande",
                model: "gpt-5.6-luna",
                systemPrompt: "Réécris.",
                userPrompt: "une demande"
            )
            XCTFail("An empty Prompt Mode response must be rejected")
        } catch OpenAIClientError.emptyPromptResponse {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetriesTransientNetworkFailureThenSucceeds() async throws {
        let script = ResponseScript([
            .failure(URLError(.timedOut)),
            .http(
                status: 200,
                body: #"{"choices":[{"message":{"role":"assistant","content":"Texte final"}}]}"#,
                headers: [:]
            )
        ])
        URLProtocolStub.install(script)
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        let result = try await client.polish(
            text: "texte",
            model: "gpt-test",
            systemPrompt: "Corrige",
            userPrompt: "texte"
        )

        XCTAssertEqual(result, "Texte final")
        XCTAssertEqual(script.requestCount, 2)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [0.01])
    }

    func testRetriesRateLimitAndTransientServerFailureWithBackoff() async throws {
        let script = ResponseScript([
            .http(status: 429, body: "rate limited", headers: ["Retry-After": "0.015"]),
            .http(status: 503, body: "unavailable", headers: [:]),
            .http(
                status: 200,
                body: #"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#,
                headers: [:]
            )
        ])
        URLProtocolStub.install(script)
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        let result = try await client.polish(
            text: "texte",
            model: "gpt-test",
            systemPrompt: "Corrige",
            userPrompt: "texte"
        )

        XCTAssertEqual(result, "OK")
        XCTAssertEqual(script.requestCount, 3)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays.count, 2)
        XCTAssertEqual(recordedDelays[0], 0.015, accuracy: 0.000_001)
        XCTAssertEqual(recordedDelays[1], 0.02, accuracy: 0.000_001)
    }

    func testDoesNotRetryPermanentClientFailure() async throws {
        let script = ResponseScript([
            .http(status: 400, body: "invalid request", headers: [:]),
            .http(
                status: 200,
                body: #"{"choices":[{"message":{"role":"assistant","content":"unexpected"}}]}"#,
                headers: [:]
            )
        ])
        URLProtocolStub.install(script)
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        do {
            _ = try await client.polish(
                text: "texte",
                model: "gpt-test",
                systemPrompt: "Corrige",
                userPrompt: "texte"
            )
            XCTFail("A permanent HTTP failure should be returned immediately")
        } catch OpenAIClientError.badStatus(let statusCode, let body) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(body, "invalid request")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(script.requestCount, 1)
        let recordedDelays = await delays.snapshot()
        XCTAssertTrue(recordedDelays.isEmpty)
    }

    func testDoesNotRetryPermanentNetworkFailure() async throws {
        let script = ResponseScript([
            .failure(URLError(.badURL)),
            .http(
                status: 200,
                body: #"{"choices":[{"message":{"role":"assistant","content":"unexpected"}}]}"#,
                headers: [:]
            )
        ])
        URLProtocolStub.install(script)
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        do {
            _ = try await client.polish(
                text: "texte",
                model: "gpt-test",
                systemPrompt: "Corrige",
                userPrompt: "texte"
            )
            XCTFail("A permanent network failure should be returned immediately")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }

        XCTAssertEqual(script.requestCount, 1)
        let recordedDelays = await delays.snapshot()
        XCTAssertTrue(recordedDelays.isEmpty)
    }

    func testStopsAfterMaximumAttempts() async throws {
        let script = ResponseScript([
            .http(status: 500, body: "first", headers: [:]),
            .http(status: 502, body: "second", headers: [:]),
            .http(status: 503, body: "last", headers: [:])
        ])
        URLProtocolStub.install(script)
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        do {
            _ = try await client.polish(
                text: "texte",
                model: "gpt-test",
                systemPrompt: "Corrige",
                userPrompt: "texte"
            )
            XCTFail("The final HTTP failure should be returned")
        } catch OpenAIClientError.badStatus(let statusCode, let body) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(body, "last")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(script.requestCount, 3)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [0.01, 0.02])
    }

    func testTranscriptionUsesFileBackedUploadAndDecodesResponse() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-openai-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data(repeating: 0x42, count: 4_096).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let script = ResponseScript([
            .http(status: 200, body: #"{"text":"Bonjour LocalFlow"}"#, headers: [:])
        ])
        URLProtocolStub.install(script)
        let client = makeClient(delays: DelayRecorder())

        let result = try await client.transcribeAudio(
            fileURL: audioURL,
            model: "gpt-4o-transcribe",
            language: "fr",
            prompt: "LocalFlow"
        )

        XCTAssertEqual(result, "Bonjour LocalFlow")
        XCTAssertEqual(script.requestCount, 1)
        XCTAssertEqual(script.lastRequest?.timeoutInterval, 90)
        XCTAssertTrue(
            script.lastRequest?.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=") == true
        )
        XCTAssertNil(script.lastRequest?.httpBody)
    }

    func testTranscriptionRetriesFileBackedUpload() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-upload-retry-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try Data(repeating: 0x24, count: 8_192).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let script = ResponseScript([
            .http(status: 503, body: "unavailable", headers: [:]),
            .http(status: 200, body: #"{"text":"Nouvel essai"}"#, headers: [:])
        ])
        URLProtocolStub.install(script)
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        let result = try await client.transcribeAudio(
            fileURL: audioURL,
            model: "gpt-4o-transcribe",
            language: "fr",
            prompt: ""
        )

        XCTAssertEqual(result, "Nouvel essai")
        XCTAssertEqual(script.requestCount, 2)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [0.01])
    }

    func testTranscriptionRejectsEmptyAudioBeforeNetworkRequest() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-empty-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data().write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let script = ResponseScript([])
        URLProtocolStub.install(script)
        let client = makeClient(delays: DelayRecorder())

        do {
            _ = try await client.transcribeAudio(
                fileURL: audioURL,
                model: "gpt-4o-transcribe",
                language: "fr",
                prompt: ""
            )
            XCTFail("An empty recording must be rejected")
        } catch OpenAIClientError.audioFileEmpty {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(script.requestCount, 0)
    }

    func testTranscriptionRejectsOversizedAudioBeforeEncoding() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-oversized-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: audioURL)
        try handle.truncate(atOffset: 25 * 1_024 * 1_024 + 1)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let script = ResponseScript([])
        URLProtocolStub.install(script)
        let client = makeClient(delays: DelayRecorder())

        do {
            _ = try await client.transcribeAudio(
                fileURL: audioURL,
                model: "gpt-4o-transcribe",
                language: "fr",
                prompt: ""
            )
            XCTFail("An oversized recording must be rejected")
        } catch OpenAIClientError.audioFileTooLarge(let actual, let maximum) {
            XCTAssertGreaterThan(actual, maximum)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(script.requestCount, 0)
    }

    private func makeClient(delays: DelayRecorder) -> OpenAIClient {
        OpenAIClient(
            apiKey: "sk-test",
            session: makeSession(),
            retryPolicy: OpenAIRetryPolicy(
                maxAttempts: 3,
                initialDelay: 0.01,
                maximumDelay: 0.05
            ),
            sleeper: { delay in
                await delays.append(delay)
            }
        )
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = Array(repeating: UInt8(0), count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private actor DelayRecorder {
    private var delays: [TimeInterval] = []

    func append(_ delay: TimeInterval) {
        delays.append(delay)
    }

    func snapshot() -> [TimeInterval] {
        delays
    }
}

private final class ResponseScript: @unchecked Sendable {
    enum Outcome {
        case failure(Error)
        case http(status: Int, body: String, headers: [String: String])
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var requests = 0
    private var receivedRequests: [URLRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests.last
    }

    func next(request: URLRequest) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        requests += 1
        receivedRequests.append(request)
        guard !outcomes.isEmpty else {
            return .failure(URLError(.badServerResponse))
        }
        return outcomes.removeFirst()
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseScript: ResponseScript?

    static func install(_ script: ResponseScript?) {
        lock.lock()
        defer { lock.unlock() }
        responseScript = script
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let script = Self.responseScript
        Self.lock.unlock()

        guard let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch script.next(request: request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .http(let status, let body, let headers):
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
