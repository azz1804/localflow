import AppKit

@main
enum LocalFlowMain {
    @MainActor
    static func main() {
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
}
