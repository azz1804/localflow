import AppKit

@main
enum LocalFlowMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--probe-audio-cadence") {
            runAudioCadenceProbe()
            return
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

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    @MainActor
    private static func runAudioCadenceProbe() {
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
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            try? capture.stop()
            try? FileManager.default.removeItem(at: fileURL)
            fputs(
                "LocalFlow audio probe failed: \(error.localizedDescription)\n",
                stderr
            )
        }
    }
}
