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
        let status = await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume(
                    returning: exportSessionBox.session.status
                )
            }
        }

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

    private static let minimumCompressionByteCount: Int64 = 750_000
}
