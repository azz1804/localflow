import Foundation
import LocalFlowCore

enum LocalFlowLogger {
    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"

        do {
            let directory = try LocalFlowPaths.ensureAppSupportDirectory()
            let url = directory.appendingPathComponent("localflow.log")

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
}
