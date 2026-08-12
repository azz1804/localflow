import AppKit
import LocalFlowCore

enum HandsFreeTargetRestorationPolicy {
    static func shouldRestore(
        currentProcessIdentifier: pid_t?,
        localProcessIdentifier: pid_t,
        candidateProcessIdentifier: pid_t?,
        candidateIsTerminated: Bool
    ) -> Bool {
        currentProcessIdentifier == localProcessIdentifier
            && candidateProcessIdentifier != nil
            && candidateProcessIdentifier != localProcessIdentifier
            && !candidateIsTerminated
    }
}

@MainActor
final class ActiveApplicationProvider: NSObject {
    private enum DefaultsKey {
        static let lastExternalBundleIdentifier =
            "LocalFlow.LastExternalBundleIdentifier"
    }

    private let workspace: NSWorkspace
    private let defaults: UserDefaults
    private let localProcessIdentifier: pid_t
    private let localBundleIdentifier: String?
    private var lastExternalApplication: NSRunningApplication?

    init(
        workspace: NSWorkspace = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.workspace = workspace
        self.defaults = defaults
        localProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        localBundleIdentifier = Bundle.main.bundleIdentifier
        super.init()

        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        rememberIfExternal(workspace.frontmostApplication)
    }

    func currentApplication() -> TargetApplicationInfo {
        let application = workspace.frontmostApplication
        rememberIfExternal(application)
        return TargetApplicationInfo(
            localizedName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier
        )
    }

    /// A clap can be detected while the LocalFlow dashboard is key even though
    /// the user left a text editor ready immediately behind it. Restore that
    /// last external application before the insertion target is captured so
    /// the normal safe auto-paste pipeline can be reused unchanged.
    func restoreExternalTargetForDoubleClap() async {
        let currentApplication = workspace.frontmostApplication
        rememberIfExternal(currentApplication)
        guard let candidate = resolvedLastExternalApplication(),
              HandsFreeTargetRestorationPolicy.shouldRestore(
                currentProcessIdentifier:
                    currentApplication?.processIdentifier,
                localProcessIdentifier: localProcessIdentifier,
                candidateProcessIdentifier: candidate.processIdentifier,
                candidateIsTerminated: candidate.isTerminated
              ) else {
            return
        }

        LocalFlowLogger.log(
            "Double-clap restoring insertion target pid=\(candidate.processIdentifier) bundle=\(candidate.bundleIdentifier ?? "-")"
        )
        _ = candidate.activate(options: [])

        // Activation is asynchronous. Wait briefly for AppKit/Accessibility
        // to expose the restored focused field before captureTarget() runs.
        for _ in 0..<10 {
            if workspace.frontmostApplication?.processIdentifier
                == candidate.processIdentifier {
                LocalFlowLogger.log(
                    "Double-clap insertion target restored"
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        LocalFlowLogger.log(
            "Double-clap insertion target restoration timed out"
        )
    }

    @objc nonisolated private func applicationDidActivate(
        _ notification: Notification
    ) {
        let callbackValue = AppKitCallbackValue(value: notification)
        AppKitMainThreadBridge.run {
            let application = callbackValue.value.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            rememberIfExternal(application)
        }
    }

    private func rememberIfExternal(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != localProcessIdentifier,
              application.bundleIdentifier != localBundleIdentifier,
              !application.isTerminated else {
            return
        }
        lastExternalApplication = application
        if let bundleIdentifier = application.bundleIdentifier {
            defaults.set(
                bundleIdentifier,
                forKey: DefaultsKey.lastExternalBundleIdentifier
            )
        }
    }

    private func resolvedLastExternalApplication() -> NSRunningApplication? {
        if let lastExternalApplication,
           !lastExternalApplication.isTerminated {
            return lastExternalApplication
        }
        guard let bundleIdentifier = defaults.string(
            forKey: DefaultsKey.lastExternalBundleIdentifier
        ) else {
            return nil
        }
        let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first(where: { !$0.isTerminated })
        lastExternalApplication = application
        return application
    }
}
