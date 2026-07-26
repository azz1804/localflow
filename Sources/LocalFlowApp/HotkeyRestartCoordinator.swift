struct HotkeyRestartCoordinator {
    private(set) var isRestartDeferred = false

    mutating func requestRestart(recordingIsActive: Bool) -> Bool {
        guard !recordingIsActive else {
            isRestartDeferred = true
            return false
        }

        isRestartDeferred = false
        return true
    }

    mutating func consumeDeferredRestart(
        recordingIsActive: Bool
    ) -> Bool {
        guard isRestartDeferred, !recordingIsActive else {
            return false
        }

        isRestartDeferred = false
        return true
    }
}
