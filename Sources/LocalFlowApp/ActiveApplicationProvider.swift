import AppKit
import LocalFlowCore

struct ActiveApplicationProvider {
    func currentApplication() -> TargetApplicationInfo {
        let application = NSWorkspace.shared.frontmostApplication
        return TargetApplicationInfo(
            localizedName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier
        )
    }
}
