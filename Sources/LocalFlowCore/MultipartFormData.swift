import Foundation

/// A multipart body that keeps file parts file-backed until it is encoded.
/// `write(to:)` streams those parts in bounded chunks, avoiding a second full
/// copy of long recordings in memory.
public struct MultipartFormData: Sendable {
    private enum Part: Sendable {
        case bytes(Data)
        case file(URL)
    }

    public let boundary: String
    private var parts: [Part]
    private var isFinalized = false

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-'()+_.,/:=?")
        )
        let sanitizedScalars = boundary.unicodeScalars.filter {
            allowed.contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(sanitizedScalars))
        self.boundary = sanitized.isEmpty
            ? "Boundary-\(UUID().uuidString)"
            : String(sanitized.prefix(70))
        self.parts = []
    }

    public mutating func appendField(name: String, value: String) {
        guard !isFinalized else {
            return
        }
        let safeName = Self.headerToken(name)
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"\(safeName)\"\r\n\r\n"
        )
        appendString("\(value)\r\n")
    }

    public mutating func appendFile(
        name: String,
        fileURL: URL,
        filename: String,
        mimeType: String
    ) throws {
        guard !isFinalized else {
            return
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let safeName = Self.headerToken(name)
        let safeFilename = Self.headerToken(filename)
        let safeMimeType = Self.mimeTypeToken(mimeType)
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"\(safeName)\"; filename=\"\(safeFilename)\"\r\n"
        )
        appendString("Content-Type: \(safeMimeType)\r\n\r\n")
        parts.append(.file(fileURL))
        appendString("\r\n")
    }

    public mutating func finalize() {
        guard !isFinalized else {
            return
        }
        appendString("--\(boundary)--\r\n")
        isFinalized = true
    }

    /// Compatibility accessor for callers that explicitly need an in-memory
    /// representation. Network uploads should use `write(to:)` instead.
    public var data: Data {
        (try? encodedData()) ?? Data()
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public func contentLength() throws -> UInt64 {
        var length: UInt64 = 0
        for part in parts {
            switch part {
            case .bytes(let data):
                length = try Self.adding(UInt64(data.count), to: length)
            case .file(let url):
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size >= 0 else {
                    throw CocoaError(.fileReadUnknown)
                }
                length = try Self.adding(UInt64(size), to: length)
            }
        }
        return length
    }

    public func write(to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let output = try FileHandle(forWritingTo: destinationURL)
            defer { try? output.close() }

            for part in parts {
                try Task.checkCancellation()
                switch part {
                case .bytes(let data):
                    try output.write(contentsOf: data)
                case .file(let sourceURL):
                    let input = try FileHandle(forReadingFrom: sourceURL)
                    defer { try? input.close() }
                    while true {
                        try Task.checkCancellation()
                        guard let chunk = try input.read(upToCount: 64 * 1_024),
                              !chunk.isEmpty else {
                            break
                        }
                        try output.write(contentsOf: chunk)
                    }
                }
            }
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func encodedData() throws -> Data {
        let length = try contentLength()
        guard length <= UInt64(Int.max) else {
            throw CocoaError(.fileReadTooLarge)
        }
        var result = Data()
        result.reserveCapacity(Int(length))
        for part in parts {
            switch part {
            case .bytes(let data):
                result.append(data)
            case .file(let url):
                result.append(try Data(contentsOf: url, options: [.mappedIfSafe]))
            }
        }
        return result
    }

    private mutating func appendString(_ string: String) {
        parts.append(.bytes(Data(string.utf8)))
    }

    private static func headerToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
    }

    private static func mimeTypeToken(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "application/octet-stream" : sanitized
    }

    private static func adding(_ value: UInt64, to total: UInt64) throws -> UInt64 {
        let (result, overflow) = total.addingReportingOverflow(value)
        guard !overflow else {
            throw CocoaError(.fileReadTooLarge)
        }
        return result
    }
}
