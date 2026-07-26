import Foundation
import XCTest
@testable import LocalFlowCore

final class OpenAIClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.install(nil)
        super.tearDown()
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

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func next() -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        requests += 1
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

        switch script.next() {
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
