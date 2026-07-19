import AppKit
import LocalFlowCore
import SwiftUI

@MainActor
enum LocalFlowUIPreviewRenderer {
    static func render(to outputDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let model = makeModel()
        try renderHub(
            model: model,
            section: .home,
            colorScheme: .dark,
            to: outputDirectory.appendingPathComponent("localflow-home.png")
        )
        try renderHub(
            model: model,
            section: .history,
            colorScheme: .dark,
            to: outputDirectory.appendingPathComponent("localflow-history.png")
        )
        try renderHub(
            model: model,
            section: .insights,
            colorScheme: .dark,
            to: outputDirectory.appendingPathComponent("localflow-insights.png")
        )
        try renderHub(
            model: model,
            section: .home,
            colorScheme: .light,
            to: outputDirectory.appendingPathComponent("localflow-home-light.png")
        )
        try renderFloatingBar(
            to: outputDirectory.appendingPathComponent("localflow-flowbar.png")
        )
    }

    private static func renderHub(
        model: LocalFlowHubModel,
        section: LocalFlowHubSection,
        colorScheme: ColorScheme,
        to outputURL: URL
    ) throws {
        model.selectedSection = section
        let size = NSSize(width: 1120, height: 760)
        let hostingView = NSHostingView(
            rootView: LocalFlowHubView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, colorScheme)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = .windowBackgroundColor
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try writePNG(of: hostingView, to: outputURL)
        window.orderOut(nil)
    }

    private static func renderFloatingBar(to outputURL: URL) throws {
        let view = FloatingBarView(frame: NSRect(x: 0, y: 0, width: 420, height: 86))
        view.status = .recording(18.4, .toggle)

        let levels: [Float] = [
            0.06, 0.12, 0.28, 0.62, 0.91, 0.7, 0.34, 0.18, 0.4, 0.82,
            0.58, 0.24, 0.12, 0.36, 0.76, 0.94, 0.56, 0.2, 0.1, 0.32,
            0.68, 0.44, 0.16, 0.08, 0.22, 0.5, 0.79, 0.52, 0.2, 0.08
        ]
        for level in levels {
            view.pushWaveformSample(level, reduceMotion: false)
        }
        try writePNG(of: view, to: outputURL)
    }

    private static func writePNG(of view: NSView, to outputURL: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewError.renderFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.renderFailed
        }
        try data.write(to: outputURL, options: .atomic)
    }

    private static func makeModel() -> LocalFlowHubModel {
        let model = LocalFlowHubModel()
        let now = Date()
        let sampleTexts = [
            "Can you prepare a clean summary of the product changes and the remaining launch risks?",
            "Bonjour, je reviens vers toi avec une version plus claire de la proposition pour lundi.",
            "Update the onboarding flow and make sure the empty states explain what happens next.",
            "Je veux une interface simple, rapide et suffisamment soignée pour devenir un vrai produit.",
            "Please review the pull request and check the migration state before we merge it.",
            "Merci pour ton retour, je vais intégrer les modifications et partager une nouvelle version.",
            "Create a short project brief with the objective, constraints, timeline, and owners.",
            "Le raccourci Échap doit arrêter l'enregistrement puis lancer la transcription.",
            "Let's simplify the settings screen and make the important controls easier to discover.",
            "Prépare un message concis pour expliquer le nouveau fonctionnement à toute l'équipe."
        ]
        let apps = [
            TargetApplicationInfo(localizedName: "Codex", bundleIdentifier: "com.openai.codex"),
            TargetApplicationInfo(localizedName: "Messages", bundleIdentifier: "com.apple.MobileSMS"),
            TargetApplicationInfo(localizedName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
            TargetApplicationInfo(localizedName: "Notion", bundleIdentifier: "notion.id")
        ]

        var records: [DictationRecord] = []
        for index in 0..<26 {
            let text = sampleTexts[index % sampleTexts.count]
            let dayOffset = index % 12
            let createdAt = Calendar.current.date(
                byAdding: .day,
                value: -dayOffset,
                to: now.addingTimeInterval(-Double(index % 5) * 1_900)
            ) ?? now
            records.append(
                DictationRecord(
                    createdAt: createdAt,
                    targetApplication: apps[index % apps.count],
                    transcribedText: text,
                    finalText: text,
                    polished: index.isMultiple(of: 3),
                    durationSeconds: Double(7 + (index % 9))
                )
            )
        }
        records.sort { $0.createdAt > $1.createdAt }

        model.update(
            configuration: AppConfiguration(openAIAPIKey: "sk-localflow-preview"),
            dictionary: PersonalDictionary(
                terms: ["LocalFlow", "Codex", "Supabase", "Grégoire"],
                replacements: ["code ex": "Codex", "local flow": "LocalFlow"]
            ),
            historyRecords: records,
            diagnosticInfo: LocalFlowDiagnosticInfo(
                hotkeyStatus: "Hotkeys: Active (hid-active+monitor+carbon+hid)",
                lastHotkey: "Escape via CG key",
                accessibilityStatus: "Granted",
                inputMonitoringStatus: "Granted",
                fnGlobeAction: "Do Nothing",
                envPath: "~/Library/Application Support/LocalFlow/.env",
                dictionaryPath: "~/Library/Application Support/LocalFlow/dictionary.json",
                historyPath: "~/Library/Application Support/LocalFlow/history.jsonl",
                localDataPath: "~/Library/Application Support/LocalFlow",
                logPath: "~/Library/Application Support/LocalFlow/localflow.log",
                appPath: "/Applications/LocalFlow.app"
            )
        )
        return model
    }
}

private enum PreviewError: Error {
    case renderFailed
}
