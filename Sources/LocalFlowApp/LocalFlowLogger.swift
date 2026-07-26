import Foundation
import LocalFlowCore

enum LocalFlowLogger {
    private static let lock = NSLock()
    private static let maximumLogBytes: UInt64 = 2 * 1_024 * 1_024

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"

        do {
            let directory = try LocalFlowPaths.ensureAppSupportDirectory()
            let url = directory.appendingPathComponent("localflow.log")
            try rotateIfNeeded(url: url, in: directory)

            if !FileManager.default.fileExists(atPath: url.path) {
                try line.write(to: url, atomically: true, encoding: .utf8)
                return
            }

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            NSLog("LocalFlow log failed: \(error.localizedDescription)")
        }
    }

    private static func rotateIfNeeded(url: URL, in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let fileSize = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              fileSize.uint64Value >= maximumLogBytes else {
            return
        }

        let previousURL = directory.appendingPathComponent(
            "localflow.previous.log"
        )
        if FileManager.default.fileExists(atPath: previousURL.path) {
            try FileManager.default.removeItem(at: previousURL)
        }
        try FileManager.default.moveItem(at: url, to: previousURL)
    }
}
