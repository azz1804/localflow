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
}
