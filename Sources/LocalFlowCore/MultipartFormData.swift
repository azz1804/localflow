import Foundation

public struct MultipartFormData: Sendable {
    public let boundary: String
    public private(set) var data: Data

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
        self.data = Data()
    }

    public mutating func appendField(name: String, value: String) {
        data.appendString("--\(boundary)\r\n")
        data.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.appendString("\(value)\r\n")
    }

    public mutating func appendFile(name: String, fileURL: URL, filename: String, mimeType: String) throws {
        let fileData = try Data(contentsOf: fileURL)
        data.appendString("--\(boundary)\r\n")
        data.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        data.appendString("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        data.appendString("\r\n")
    }

    public mutating func finalize() {
        data.appendString("--\(boundary)--\r\n")
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
