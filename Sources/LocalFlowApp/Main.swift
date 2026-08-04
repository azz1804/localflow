import AppKit
import Darwin
import LocalFlowCore

enum LocalFlowActivationSignal {
    static let showDashboard = Notification.Name(
        "local.localflow.app.show-dashboard"
    )

    static var dashboardRequestURL: URL {
        LocalFlowPaths.appSupportDirectory
            .appendingPathComponent("show-dashboard.request")
    }

    @discardableResult
    static func persistDashboardRequest(
        at requestURL: URL = dashboardRequestURL
    ) -> Bool {
        do {
            let directory = requestURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data([1]).write(to: requestURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: requestURL.path
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func consumeDashboardRequest(
        at requestURL: URL = dashboardRequestURL
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            return false
        }
        try? FileManager.default.removeItem(at: requestURL)
        return true
    }
}

@main
enum LocalFlowMain {
    @MainActor
    static func main() {
        if let brandAssetsIndex = CommandLine.arguments.firstIndex(
            of: "--render-brand-assets"
        ),
           CommandLine.arguments.indices.contains(brandAssetsIndex + 1) {
            let outputDirectory = URL(
                fileURLWithPath: CommandLine.arguments[brandAssetsIndex + 1],
                isDirectory: true
            )
            do {
                try LocalFlowUIPreviewRenderer.renderBrandAssets(
                    to: outputDirectory
                )
            } catch {
                fputs(
                    "LocalFlow brand rendering failed: \(error.localizedDescription)\n",
                    stderr
                )
            }
            return
        }

        if CommandLine.arguments.contains("--probe-audio-cadence") {
            Darwin.exit(runAudioCadenceProbe())
        }

        if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-ui-preview"),
           CommandLine.arguments.indices.contains(previewIndex + 1) {
            let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1], isDirectory: true)
            do {
                try LocalFlowUIPreviewRenderer.render(to: outputDirectory)
            } catch {
                fputs("LocalFlow UI preview failed: \(error.localizedDescription)\n", stderr)
            }
            return
        }

        // A second instance would register duplicate global hotkeys and could
        // concurrently append to the same history/pending stores. Bring the
        // existing app forward instead.
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           let existingApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }) {
            LocalFlowActivationSignal.persistDashboardRequest()
            DistributedNotificationCenter.default().postNotificationName(
                LocalFlowActivationSignal.showDashboard,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            existingApplication.activate(options: [.activateAllWindows])
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    @MainActor
    private static func runAudioCadenceProbe() -> Int32 {
        let capture = MicrophoneAudioCapture()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-audio-probe")
            .appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: fileURL)

        do {
            try capture.start(recordingURL: fileURL)
            let endDate = Date().addingTimeInterval(1.6)
            while Date() < endDate {
                RunLoop.main.run(
                    until: Date().addingTimeInterval(1 / 60)
                )
                _ = capture.currentFrame()
            }
            try capture.stop()
            let validation = AudioRecordingValidator.validate(at: fileURL)
            guard validation == .usable else {
                if validation == .digitalSilence {
                    throw AudioRecorderError.recordingSilent
                }
                throw AudioRecorderError.recordingUnavailable
            }
            let byteCount = (
                try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            ) ?? 0
            print("LocalFlow audio probe passed bytes=\(byteCount)")
            try? FileManager.default.removeItem(at: fileURL)
            return EXIT_SUCCESS
        } catch {
            try? capture.stop()
            try? FileManager.default.removeItem(at: fileURL)
            fputs(
                "LocalFlow audio probe failed: \(error.localizedDescription)\n",
                stderr
            )
            return EXIT_FAILURE
        }
    }

}
