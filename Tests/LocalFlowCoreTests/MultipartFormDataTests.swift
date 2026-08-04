import Foundation
import XCTest
@testable import LocalFlowCore

final class MultipartFormDataTests: XCTestCase {
    func testMultipartContainsFieldsAndFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowMultipart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: fileURL)

        var form = MultipartFormData(boundary: "Boundary-Test")
        form.appendField(name: "model", value: "gpt-4o-transcribe")
        try form.appendFile(name: "file", fileURL: fileURL, filename: "audio.m4a", mimeType: "audio/mp4")
        form.finalize()

        let body = String(data: form.data, encoding: .utf8)
        XCTAssertTrue(body?.contains("name=\"model\"") == true)
        XCTAssertTrue(body?.contains("gpt-4o-transcribe") == true)
        XCTAssertTrue(body?.contains("filename=\"audio.m4a\"") == true)
        XCTAssertTrue(body?.contains("audio") == true)
        XCTAssertTrue(form.contentType.contains("Boundary-Test"))

        try? FileManager.default.removeItem(at: directory)
    }

    func testMultipartWritesFileBackedBodyWithExactContentLength() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LocalFlowMultipartStream-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("voice.wav")
        let destinationURL = directory.appendingPathComponent("body.multipart")
        let payload = Data(repeating: 0x5A, count: 2 * 1_024 * 1_024)
        try payload.write(to: sourceURL)

        var form = MultipartFormData(boundary: "Boundary-Stream-Test")
        form.appendField(name: "model", value: "gpt-test")
        try form.appendFile(
            name: "file",
            fileURL: sourceURL,
            filename: "voice.wav",
            mimeType: "audio/wav"
        )
        form.finalize()

        try form.write(to: destinationURL)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )
        let writtenByteCount = (attributes[.size] as? NSNumber)?.uint64Value
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

        XCTAssertEqual(writtenByteCount, try form.contentLength())
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
        let body = try Data(contentsOf: destinationURL)
        XCTAssertTrue(body.starts(with: Data("--Boundary-Stream-Test".utf8)))
        XCTAssertNotNil(body.range(of: Data(payload.prefix(128))))
        XCTAssertTrue(
            Data(body.suffix(32)).range(
                of: Data("Boundary-Stream-Test--".utf8)
            ) != nil
        )
    }

    func testMultipartSanitizesHeaderInjectionAndFinalizeIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowMultipartHeaders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("audio.wav")
        try Data("voice".utf8).write(to: fileURL)

        var form = MultipartFormData(boundary: "Boundary-Headers")
        try form.appendFile(
            name: "file\r\nX-Injected: yes",
            fileURL: fileURL,
            filename: "voice\"\r\nX-Injected: yes.wav",
            mimeType: "audio/wav\r\nX-Injected: yes"
        )
        form.finalize()
        let length = try form.contentLength()
        form.finalize()

        let body = String(data: form.data, encoding: .utf8) ?? ""
        XCTAssertEqual(try form.contentLength(), length)
        XCTAssertFalse(body.contains("\r\nX-Injected"))
        XCTAssertEqual(
            body.components(separatedBy: "--Boundary-Headers--").count - 1,
            1
        )
    }
}
