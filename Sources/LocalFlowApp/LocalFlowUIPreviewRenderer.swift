import AppKit
import LocalFlowCore
import SwiftUI

@MainActor
enum LocalFlowUIPreviewRenderer {
    static func renderBrandAssets(to outputDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try renderSwiftUIView(
            LocalFlowAppIconArtwork(),
            size: NSSize(width: 1_024, height: 1_024),
            to: outputDirectory.appendingPathComponent("AppIcon.png")
        )
        try renderSwiftUIView(
            LocalFlowBrandOrb(diameter: 224)
                .frame(width: 256, height: 256),
            size: NSSize(width: 256, height: 256),
            to: outputDirectory.appendingPathComponent("BrandOrb.png")
        )
        try renderSwiftUIView(
            LocalFlowCompactAppIconArtwork(),
            size: NSSize(width: 256, height: 256),
            to: outputDirectory.appendingPathComponent("CompactAppIcon.png")
        )
        try renderSwiftUIView(
            LocalFlowCompactBrandOrb(diameter: 64)
                .frame(width: 72, height: 72),
            size: NSSize(width: 72, height: 72),
            to: outputDirectory.appendingPathComponent("MenuBarOrb.png")
        )
    }

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
        for theme in OrbEvolution.themes {
            let themedModel = makeModel()
            themedModel.configuration.orbThemeOverride = theme.id
            try renderHub(
                model: themedModel,
                section: .home,
                colorScheme: .dark,
                to: outputDirectory.appendingPathComponent(
                    "localflow-home-\(theme.id).png"
                )
            )
        }
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
        let settingsModel = makeModel()
        settingsModel.configuration.outputMode = .prompt
        try renderHub(
            model: settingsModel,
            section: .settings,
            colorScheme: .dark,
            to: outputDirectory.appendingPathComponent("localflow-settings.png")
        )
        try renderHub(
            model: model,
            section: .home,
            colorScheme: .light,
            to: outputDirectory.appendingPathComponent("localflow-home-light.png")
        )
        try renderFloatingBar(
            hovered: false,
            orbThemeOverride: "automatic",
            to: outputDirectory.appendingPathComponent("localflow-flowbar.png")
        )
        try renderFloatingBar(
            hovered: false,
            outputMode: .prompt,
            orbThemeOverride: "automatic",
            to: outputDirectory.appendingPathComponent(
                "localflow-flowbar-prompt-mode.png"
            )
        )
        try renderFloatingBar(
            hovered: true,
            orbThemeOverride: "automatic",
            to: outputDirectory.appendingPathComponent("localflow-flowbar-hover.png")
        )
        try renderFloatingBar(
            hovered: false,
            processing: true,
            orbThemeOverride: "automatic",
            to: outputDirectory.appendingPathComponent(
                "localflow-flowbar-processing.png"
            )
        )
        for theme in OrbEvolution.themes {
            try renderFloatingBar(
                hovered: false,
                orbThemeOverride: theme.id,
                to: outputDirectory.appendingPathComponent(
                    "localflow-flowbar-\(theme.id).png"
                )
            )
        }
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

    private static func renderFloatingBar(
        hovered: Bool,
        processing: Bool = false,
        outputMode: DictationOutputMode = .transcript,
        orbThemeOverride: String,
        to outputURL: URL
    ) throws {
        let view = FloatingBarView(
            frame: NSRect(
                origin: .zero,
                size: FloatingBarController.panelSize
            )
        )
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        window.orderFrontRegardless()
        view.updateOrbProgression(
            totalWords: 0,
            overrideID: orbThemeOverride
        )
        view.updateOutputMode(outputMode)

        let liveEnvelope: [Float] = [
            0.74, 0.92, 0.7, 0.82, 0.54, 0.68, 0.4,
            0.5, 0.28, 0.34, 0.2, 0.24, 0.14, 0.08
        ]
        for index in 0..<4 {
            view.update(
                status: .recording(18.4, .toggle),
                visualization: AudioVisualizationFrame(
                    sequence: UInt64(index + 1),
                    sample: AudioWaveformSample(
                        rootMeanSquare: 0.58,
                        positivePeak: 0.92,
                        negativePeak: 0.84
                    ),
                    liveEnvelope: liveEnvelope,
                    voiceLevel: 0.88
                ),
                reduceMotion: false
            )
        }
        if hovered {
            view.setHoveredForPreview(
                true,
                location: NSPoint(x: 210, y: 36)
            )
        }
        if processing {
            view.update(
                status: .processing,
                visualization: .silent,
                reduceMotion: false
            )
        }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(
            until: Date().addingTimeInterval(processing ? 0.46 : 0.24)
        )
        try writePNG(of: view, to: outputURL)
        window.orderOut(nil)
    }

    private static func renderSwiftUIView<Content: View>(
        _ content: Content,
        size: NSSize,
        to outputURL: URL
    ) throws {
        let hostingView = NSHostingView(
            rootView: content
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        try writePNG(of: hostingView, to: outputURL)
        window.orderOut(nil)
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
        model.isHubAnimationActive = true
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
