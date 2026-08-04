import Foundation
import LocalFlowCore

enum LocalFlowLogger {
    private static let queue = DispatchQueue(
        label: "local.localflow.logger",
        qos: .utility
    )
    private static let maximumLogBytes: UInt64 = 2 * 1_024 * 1_024
    private static let isRunningTests: Bool = {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        // Recent SwiftPM/Xcode versions do not consistently expose the
        // XCTestConfigurationFilePath variable. The test runner itself is
        // still an .xctest bundle, so detect it without importing XCTest in
        // the production target.
        if Bundle.main.bundleURL.pathExtension == "xctest" {
            return true
        }

        return processInfo.arguments.contains { argument in
            argument.contains(".xctest/") || argument.hasSuffix(".xctest")
        }
    }()

    static func log(_ message: String) {
        guard !isRunningTests else {
            return
        }
        queue.async {
            write(message)
        }
    }

    static func flush() {
        queue.sync {}
    }

    private static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"

        do {
            let directory = try LocalFlowPaths.ensureAppSupportDirectory()
            let url = directory.appendingPathComponent("localflow.log")
            try rotateIfNeeded(url: url, in: directory)

            if !FileManager.default.fileExists(atPath: url.path) {
                try line.write(to: url, atomically: true, encoding: .utf8)
                try setPrivatePermissions(on: url)
                return
            }

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try setPrivatePermissions(on: url)
        } catch {
            NSLog("LocalFlow log failed: \(error.localizedDescription)")
        }
    }

    private static func setPrivatePermissions(on url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
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
