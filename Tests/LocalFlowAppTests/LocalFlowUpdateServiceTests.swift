import Foundation
import XCTest
@testable import LocalFlowApp

final class LocalFlowUpdateServiceTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        UpdateURLProtocol.handler = nil
        super.tearDown()
    }

    func testCommitComparisonAcceptsBundledShortSHAAndDirtySuffix() {
        XCTAssertTrue(
            LocalFlowUpdateService.commitsMatch(
                "7A51EF4B2483-dirty",
                "7a51ef4b248324d2b613b09e900f767a52f914aa"
            )
        )
        XCTAssertFalse(
            LocalFlowUpdateService.commitsMatch(
                "7a51ef4b2483",
                "aed4c9fec77e5c12ffd6f3773420de0d9747403f"
            )
        )
        XCTAssertFalse(
            LocalFlowUpdateService.isComparableCommit("unknown")
        )
    }

    func testAvailableUpdateReturnsRemoteCommitWhenItDiffers() async throws {
        let remoteCommit = "aed4c9fec77e5c12ffd6f3773420de0d9747403f"
        UpdateURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LocalFlow-Update-Checker")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data("{\"sha\":\"\(remoteCommit)\"}".utf8))
        }

        let update = try await LocalFlowUpdateService().availableUpdate(
            installedCommit: "7a51ef4b248324d2b613b09e900f767a52f914aa",
            session: makeSession()
        )

        XCTAssertEqual(update?.commit, remoteCommit)
        XCTAssertEqual(update?.shortCommit, "aed4c9f")
    }

    func testAvailableUpdateReturnsNilForSameCommit() async throws {
        let remoteCommit = "7a51ef4b248324d2b613b09e900f767a52f914aa"
        UpdateURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data("{\"sha\":\"\(remoteCommit)\"}".utf8))
        }

        let update = try await LocalFlowUpdateService().availableUpdate(
            installedCommit: "7a51ef4b2483",
            session: makeSession()
        )

        XCTAssertNil(update)
    }

    func testInstallerDownloadIsPinnedAndValidated() async throws {
        let remoteCommit = "aed4c9fec77e5c12ffd6f3773420de0d9747403f"
        UpdateURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains(remoteCommit) == true)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            let script = "#!/usr/bin/env bash\n# LocalFlow\nLOCALFLOW_REPOSITORY=ok\n"
            return (response, Data(script.utf8))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let installer = try await LocalFlowUpdateService().downloadInstaller(
            for: LocalFlowAvailableUpdate(commit: remoteCommit),
            destinationDirectory: directory,
            session: makeSession()
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.path))
        XCTAssertTrue(installer.lastPathComponent.contains("aed4c9f"))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class UpdateURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
