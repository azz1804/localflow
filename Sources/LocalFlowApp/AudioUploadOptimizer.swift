@preconcurrency import AVFoundation
import Foundation

struct OptimizedAudioUpload {
    var fileURL: URL
    var originalByteCount: Int64
    var uploadByteCount: Int64
    var preparationDuration: TimeInterval
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

private final class ExportContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AVAssetExportSession.Status, Never>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        continuation: CheckedContinuation<AVAssetExportSession.Status, Never>
    ) {
        self.continuation = continuation
    }

    func finish(with status: AVAssetExportSession.Status) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let timeoutWorkItem = timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()
        timeoutWorkItem?.cancel()
        continuation?.resume(returning: status)
    }

    func installTimeout(_ workItem: DispatchWorkItem) {
        lock.lock()
        if continuation == nil {
            lock.unlock()
            workItem.cancel()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
    }
}

@MainActor
enum AudioUploadOptimizer {
    static func prepare(_ sourceURL: URL) async -> OptimizedAudioUpload {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let originalByteCount = byteCount(of: sourceURL)
        guard originalByteCount >= minimumCompressionByteCount else {
            return fallback(
                sourceURL: sourceURL,
                originalByteCount: originalByteCount,
                startedAt: startedAt
            )
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-upload-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(
            asset: AVURLAsset(url: sourceURL),
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            return fallback(
                sourceURL: sourceURL,
                originalByteCount: originalByteCount,
                startedAt: startedAt
            )
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true

        let exportSessionBox = ExportSessionBox(exportSession)
        let status = await export(
            exportSessionBox,
            timeout: exportTimeout
        )

        let uploadByteCount = byteCount(of: destinationURL)
        guard status == .completed,
              uploadByteCount > 0,
              uploadByteCount < originalByteCount else {
            try? FileManager.default.removeItem(at: destinationURL)
            return fallback(
                sourceURL: sourceURL,
                originalByteCount: originalByteCount,
                startedAt: startedAt
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )

        return OptimizedAudioUpload(
            fileURL: destinationURL,
            originalByteCount: originalByteCount,
            uploadByteCount: uploadByteCount,
            preparationDuration: ProcessInfo.processInfo.systemUptime
                - startedAt
        )
    }

    private static func fallback(
        sourceURL: URL,
        originalByteCount: Int64,
        startedAt: TimeInterval
    ) -> OptimizedAudioUpload {
        OptimizedAudioUpload(
            fileURL: sourceURL,
            originalByteCount: originalByteCount,
            uploadByteCount: originalByteCount,
            preparationDuration: ProcessInfo.processInfo.systemUptime
                - startedAt
        )
    }

    private static func byteCount(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func export(
        _ box: ExportSessionBox,
        timeout: TimeInterval
    ) async -> AVAssetExportSession.Status {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let gate = ExportContinuationGate(continuation: continuation)
                box.session.exportAsynchronously {
                    gate.finish(with: box.session.status)
                }
                let timeoutWorkItem = DispatchWorkItem {
                    box.session.cancelExport()
                    gate.finish(with: .cancelled)
                }
                gate.installTimeout(timeoutWorkItem)
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWorkItem
                )
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    private static let minimumCompressionByteCount: Int64 = 750_000
    private static let exportTimeout: TimeInterval = 30
}
