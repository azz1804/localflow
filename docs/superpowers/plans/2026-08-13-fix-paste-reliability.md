# Fix Paste Reliability (Electron/Chromium targets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make dictation paste reliably into Electron/Chromium apps (Claude Desktop) by fixing keystroke delivery, confirmation timing, retry behavior, and focus-identity comparison in `TextInsertionService`.

**Architecture:** All changes live in `Sources/LocalFlowApp/TextInsertionService.swift` and its test file. Decision logic stays in `nonisolated static` pure functions (unit-tested); side-effectful AX/CGEvent code changes minimally. Four independent fixes: (1) split the ambiguous `.mismatch` confirmation into `.focusChanged`/`.deltaMismatch` and add a retry policy, (2) post Cmd-V globally via the HID tap instead of `postToPid` (v0.1.0's proven mechanism), (3) poll the Accessibility confirmation for up to 1 s instead of a single 100 ms check, and retry the keystroke once on `.deltaMismatch`, (4) relax the AX focus-identity comparison so Chromium's regenerated AX wrappers don't force the fragile keyboard path.

**Tech Stack:** Swift 5 (SPM), XCTest, AppKit/ApplicationServices (AXUIElement, CGEvent). No new dependencies.

## Global Constraints

- Repo: `/Users/isidore/dev/localflow`, work on branch `fix/paste-reliability` (create from `main` at `a3538d1` before Task 1; all commits go there; never push).
- Build/test with `swift test` (run from repo root). Full suite must pass after every task.
- Match existing code style: 4-space indent, `LocalFlowLogger.log("...")` key=value log style, XCTest with `XCTAssertEqual`/`XCTAssertTrue`, test names `test<Behavior>`.
- Comments explain constraints/why (matching existing file style), never narrate the change.
- Log messages must keep the exact prefix `Keyboard paste` for paste-path events (log-grep compatibility).
- Do NOT touch `DictationController.swift`, `install.sh`, or any script. Only `Sources/LocalFlowApp/TextInsertionService.swift` and `Tests/LocalFlowAppTests/TextInsertionServiceTests.swift`.

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/isidore/dev/localflow
git checkout main
git checkout -b fix/paste-reliability
```

Expected: `Switched to a new branch 'fix/paste-reliability'`. Working tree must be clean apart from untracked `.vscode/` and `docs/superpowers/`.

- [ ] **Step 2: Commit the plan document**

```bash
git add docs/superpowers/plans/2026-08-13-fix-paste-reliability.md
git commit -m "docs: add paste reliability fix plan"
```

---

### Task 1: Split `.mismatch` into `.focusChanged` / `.deltaMismatch` and add retry policy

**Files:**
- Modify: `Sources/LocalFlowApp/TextInsertionService.swift` (enum `KeyboardPasteConfirmation` ~line 29, `keyboardPasteConfirmation` ~line 364, `keyboardPasteResolution` ~line 380, the `switch confirmation` logging block ~line 215)
- Test: `Tests/LocalFlowAppTests/TextInsertionServiceTests.swift`

**Interfaces:**
- Consumes: existing `KeyboardPasteConfirmation`, `KeyboardPasteResolution`, `KeyboardPasteDestination`.
- Produces (used by Task 3):
  - `enum KeyboardPasteConfirmation: Equatable { case confirmed, unavailable, focusChanged, deltaMismatch }` (`.mismatch` removed)
  - `nonisolated static func shouldRetryKeyboardPaste(confirmation: KeyboardPasteConfirmation, attemptCount: Int) -> Bool`
  - `keyboardPasteResolution(destination:confirmation:)` handling the two new cases exactly like the old `.mismatch`.

- [ ] **Step 1: Write the failing tests**

In `Tests/LocalFlowAppTests/TextInsertionServiceTests.swift`, replace the four tests that reference `.mismatch` (`testChangedFocusIsMismatchEvenWhenAccessibilityMetricsAreMissing`, `testChangedFocusMakesAvailableMetricsMismatch`, `testMismatchedMetricsKeepTranscriptOnClipboard`) and add the new ones:

```swift
    func testChangedFocusIsFocusChangedEvenWhenAccessibilityMetricsAreMissing() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: false,
                expectedCharacterDelta: nil,
                actualCharacterDelta: nil
            ),
            .focusChanged
        )
    }

    func testChangedFocusMakesAvailableMetricsFocusChanged() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: false,
                expectedCharacterDelta: 12,
                actualCharacterDelta: 12
            ),
            .focusChanged
        )
    }

    func testDifferentMetricsAreDeltaMismatch() {
        XCTAssertEqual(
            TextInsertionService.keyboardPasteConfirmation(
                focusStillMatches: true,
                expectedCharacterDelta: 12,
                actualCharacterDelta: 0
            ),
            .deltaMismatch
        )
    }

    func testDeltaMismatchKeepsTranscriptOnClipboard() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .capturedProcess(42),
            confirmation: .deltaMismatch
        )

        XCTAssertEqual(resolution.outcome, .copiedToClipboard)
        XCTAssertFalse(resolution.shouldRestoreClipboard)
    }

    func testFocusChangeKeepsTranscriptOnClipboard() {
        let resolution = TextInsertionService.keyboardPasteResolution(
            destination: .capturedProcess(42),
            confirmation: .focusChanged
        )

        XCTAssertEqual(resolution.outcome, .copiedToClipboard)
        XCTAssertFalse(resolution.shouldRestoreClipboard)
    }

    func testDeltaMismatchRetriesOnce() {
        XCTAssertTrue(
            TextInsertionService.shouldRetryKeyboardPaste(
                confirmation: .deltaMismatch,
                attemptCount: 1
            )
        )
        XCTAssertFalse(
            TextInsertionService.shouldRetryKeyboardPaste(
                confirmation: .deltaMismatch,
                attemptCount: 2
            )
        )
    }

    func testFocusChangeAndUnavailableAndConfirmedNeverRetry() {
        for confirmation: KeyboardPasteConfirmation in [.focusChanged, .unavailable, .confirmed] {
            XCTAssertFalse(
                TextInsertionService.shouldRetryKeyboardPaste(
                    confirmation: confirmation,
                    attemptCount: 1
                )
            )
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TextInsertionServiceTests 2>&1 | tail -20`
Expected: compilation FAILURE (`.focusChanged`, `.deltaMismatch`, `shouldRetryKeyboardPaste` do not exist).

- [ ] **Step 3: Implement the enum split and retry policy**

In `Sources/LocalFlowApp/TextInsertionService.swift`:

Replace the enum:

```swift
enum KeyboardPasteConfirmation: Equatable {
    case confirmed
    case unavailable
    case focusChanged
    case deltaMismatch
}
```

Replace `keyboardPasteConfirmation`:

```swift
    nonisolated static func keyboardPasteConfirmation(
        focusStillMatches: Bool,
        expectedCharacterDelta: Int?,
        actualCharacterDelta: Int?
    ) -> KeyboardPasteConfirmation {
        guard focusStillMatches else {
            return .focusChanged
        }
        guard let expectedCharacterDelta, let actualCharacterDelta else {
            return .unavailable
        }
        return expectedCharacterDelta == actualCharacterDelta
            ? .confirmed
            : .deltaMismatch
    }
```

In `keyboardPasteResolution`, replace `case .mismatch:` with `case .focusChanged, .deltaMismatch:` (same body).

Add after `keyboardPasteResolution`:

```swift
    // A delta mismatch with unchanged focus means the keystroke observably
    // did not land, so one more attempt cannot double-paste. A focus change
    // makes redelivery unsafe, and unavailable metrics could hide a paste
    // that already landed.
    nonisolated static func shouldRetryKeyboardPaste(
        confirmation: KeyboardPasteConfirmation,
        attemptCount: Int
    ) -> Bool {
        confirmation == .deltaMismatch && attemptCount < 2
    }
```

In the `switch confirmation` logging block inside `paste(...)` (~line 215), replace `case .unavailable, .mismatch:` with:

```swift
        case .unavailable, .focusChanged, .deltaMismatch:
```

(keep the same log message for now; Task 3 enriches it).

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalFlowApp/TextInsertionService.swift Tests/LocalFlowAppTests/TextInsertionServiceTests.swift
git commit -m "refactor: split keyboard paste mismatch into focusChanged/deltaMismatch and add retry policy"
```

---

### Task 2: Post Cmd-V globally via the HID tap instead of `postToPid`

**Files:**
- Modify: `Sources/LocalFlowApp/TextInsertionService.swift` (`postPasteEvent` ~line 649)

**Interfaces:**
- Consumes: `KeyboardPasteDestination` (unchanged — the enum still drives `keyboardPasteResolution` semantics).
- Produces: same signature `postPasteEvent(keyDown:to:)`; only the delivery mechanism changes.

**Why:** v0.1.0 posted with `CGEventSource(stateID: .hidSystemState)` + `post(tap: .cghidEventTap)` and never failed (see log session of 2026-08-12 19:12, 100% `Paste finished`). v0.3.0 switched to `.combinedSessionState` + `event.postToPid(pid)`, which Chromium/Electron apps drop or process late. The `shouldPaste` guard at line ~157 re-verifies the captured process is frontmost immediately before posting, so a global post reaches exactly that process.

- [ ] **Step 1: Replace the posting mechanism**

Replace `postPasteEvent` with:

```swift
    nonisolated private static func postPasteEvent(
        keyDown: Bool,
        to destination: KeyboardPasteDestination
    ) throws {
        // Chromium/Electron apps drop or defer events injected with
        // postToPid; the HID tap is the delivery path they reliably handle.
        // shouldPaste re-verifies the captured process is frontmost right
        // before posting, so the global event cannot reach another app.
        let stateID: CGEventSourceStateID
        switch destination {
        case .capturedProcess:
            stateID = .hidSystemState
        case .session:
            stateID = .combinedSessionState
        }
        guard let source = CGEventSource(stateID: stateID) else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        let keyCode: CGKeyCode = 9 // v

        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        event.flags = .maskCommand

        switch destination {
        case .capturedProcess:
            event.post(tap: .cghidEventTap)
        case .session:
            event.post(tap: .cgSessionEventTap)
        }
    }
```

- [ ] **Step 2: Run the full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS (this code path has no unit tests; the suite guards against regressions elsewhere).

- [ ] **Step 3: Commit**

```bash
git add Sources/LocalFlowApp/TextInsertionService.swift
git commit -m "fix: deliver paste keystroke via HID tap for Electron compatibility"
```

---

### Task 3: Poll the paste confirmation up to 1 s and retry once on delta mismatch

**Files:**
- Modify: `Sources/LocalFlowApp/TextInsertionService.swift` (the block from `try? await Task.sleep(for: .milliseconds(100))` ~line 188 through the `switch confirmation` logging ~line 226)

**Interfaces:**
- Consumes: `Self.keyboardPasteConfirmation(...)`, `Self.shouldRetryKeyboardPaste(confirmation:attemptCount:)` (Task 1), `sendPasteKeystroke(to:)`, `focusedTextTarget()`, `focusMatches(captured:current:)`, `textMetrics(for:)`, `TextMetrics`.
- Produces: private method `confirmKeyboardPaste(deliveryElement:metricsBeforePaste:text:) async -> KeyboardPasteConfirmation`; log lines `Keyboard paste confirmed via Accessibility metrics attempts=N` and `Keyboard paste unconfirmed reason=<focusChanged|deltaMismatch> attempts=N; transcript retained on clipboard`.

- [ ] **Step 1: Add the polling confirmation method**

Add as a private method of `TextInsertionService` (near `textMetrics`):

```swift
    private func confirmKeyboardPaste(
        deliveryElement: AXUIElement?,
        metricsBeforePaste: TextMetrics?,
        text: String
    ) async -> KeyboardPasteConfirmation {
        // Electron editors regularly need several hundred milliseconds to
        // process a synthetic Cmd-V; a single early check misreads slow
        // delivery as failure. Without baseline metrics no amount of polling
        // can produce evidence, so a single focus check suffices.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1_000))
        var confirmation: KeyboardPasteConfirmation = .unavailable
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
            let focusedAfterPaste = focusedTextTarget()
            let focusStillMatches = focusMatches(
                captured: deliveryElement,
                current: focusedAfterPaste.element
            )
            let metricsAfterPaste = textMetrics(for: focusedAfterPaste.element)
            let expectedCharacterDelta = metricsBeforePaste.map {
                text.utf16.count - $0.selectedCharacterCount
            }
            let actualCharacterDelta: Int?
            if let metricsBeforePaste, let metricsAfterPaste {
                actualCharacterDelta = metricsAfterPaste.characterCount
                    - metricsBeforePaste.characterCount
            } else {
                actualCharacterDelta = nil
            }
            confirmation = Self.keyboardPasteConfirmation(
                focusStillMatches: focusStillMatches,
                expectedCharacterDelta: expectedCharacterDelta,
                actualCharacterDelta: actualCharacterDelta
            )
            if confirmation == .confirmed || metricsBeforePaste == nil {
                return confirmation
            }
        } while ContinuousClock.now < deadline
        return confirmation
    }
```

- [ ] **Step 2: Replace the single-check block in `paste(...)` with polling plus retry**

Delete from `try? await Task.sleep(for: .milliseconds(100))` (~line 188) through the end of the `switch confirmation { ... }` logging block (~line 226), and replace with:

```swift
        var attemptCount = 1
        var confirmation = await confirmKeyboardPaste(
            deliveryElement: deliveryTarget.element,
            metricsBeforePaste: metricsBeforePaste,
            text: text
        )
        while Self.shouldRetryKeyboardPaste(
            confirmation: confirmation,
            attemptCount: attemptCount
        ) {
            attemptCount += 1
            LocalFlowLogger.log("Keyboard paste retry attempt=\(attemptCount)")
            do {
                try await sendPasteKeystroke(to: destination)
            } catch {
                break
            }
            confirmation = await confirmKeyboardPaste(
                deliveryElement: deliveryTarget.element,
                metricsBeforePaste: metricsBeforePaste,
                text: text
            )
        }
        let resolution = Self.keyboardPasteResolution(
            destination: destination,
            confirmation: confirmation
        )

        switch confirmation {
        case .confirmed:
            LocalFlowLogger.log(
                "Keyboard paste confirmed via Accessibility metrics attempts=\(attemptCount)"
            )
        case .unavailable where resolution.outcome == .pasted:
            LocalFlowLogger.log(
                "Keyboard paste posted to captured process; Accessibility confirmation unavailable; transcript retained on clipboard"
            )
        case .unavailable, .focusChanged, .deltaMismatch:
            LocalFlowLogger.log(
                "Keyboard paste unconfirmed reason=\(String(describing: confirmation)) attempts=\(attemptCount); transcript retained on clipboard"
            )
        }
```

Note: the old `focusedAfterPaste`/`metricsAfterPaste`/`expectedCharacterDelta`/`actualCharacterDelta` local variables and the old `let confirmation = ...`/`let resolution = ...` lines are all subsumed by the block above — none of them may remain in `paste(...)`.

- [ ] **Step 3: Run the full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/LocalFlowApp/TextInsertionService.swift
git commit -m "fix: poll paste confirmation up to 1s and retry once on delta mismatch"
```

---

### Task 4: Relax AX focus-identity comparison (pid + role fallback)

**Files:**
- Modify: `Sources/LocalFlowApp/TextInsertionService.swift` (`focusMatches` ~line 578)
- Test: `Tests/LocalFlowAppTests/TextInsertionServiceTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `nonisolated static func focusIdentityMatches(identityEqual: Bool, capturedPid: pid_t?, currentPid: pid_t?, capturedRole: String?, currentRole: String?) -> Bool` (pure, tested); `focusMatches` uses it.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LocalFlowAppTests/TextInsertionServiceTests.swift`:

```swift
    func testIdenticalElementsMatchRegardlessOfMetadata() {
        XCTAssertTrue(
            TextInsertionService.focusIdentityMatches(
                identityEqual: true,
                capturedPid: nil,
                currentPid: nil,
                capturedRole: nil,
                currentRole: nil
            )
        )
    }

    func testRegeneratedElementMatchesOnSamePidAndRole() {
        XCTAssertTrue(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 42,
                capturedRole: "AXTextArea",
                currentRole: "AXTextArea"
            )
        )
    }

    func testDifferentProcessNeverMatches() {
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 84,
                capturedRole: "AXTextArea",
                currentRole: "AXTextArea"
            )
        )
    }

    func testDifferentRoleDoesNotMatch() {
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 42,
                capturedRole: "AXTextArea",
                currentRole: "AXButton"
            )
        )
    }

    func testMissingPidOrRoleDoesNotMatch() {
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: nil,
                currentPid: nil,
                capturedRole: "AXTextArea",
                currentRole: "AXTextArea"
            )
        )
        XCTAssertFalse(
            TextInsertionService.focusIdentityMatches(
                identityEqual: false,
                capturedPid: 42,
                currentPid: 42,
                capturedRole: nil,
                currentRole: nil
            )
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TextInsertionServiceTests 2>&1 | tail -20`
Expected: compilation FAILURE (`focusIdentityMatches` does not exist).

- [ ] **Step 3: Implement the pure function and rewire `focusMatches`**

Add near the other `nonisolated static` helpers:

```swift
    // Chromium regenerates AX wrapper objects for the same DOM node, so
    // pointer inequality is not evidence that focus moved. Same process and
    // same role is the strongest identity signal still available; missing
    // metadata stays conservative and reports a mismatch.
    nonisolated static func focusIdentityMatches(
        identityEqual: Bool,
        capturedPid: pid_t?,
        currentPid: pid_t?,
        capturedRole: String?,
        currentRole: String?
    ) -> Bool {
        if identityEqual {
            return true
        }
        guard let capturedPid, let currentPid, capturedPid == currentPid else {
            return false
        }
        guard let capturedRole, let currentRole else {
            return false
        }
        return capturedRole == currentRole
    }
```

Replace `focusMatches` and add the two AX helpers:

```swift
    private func focusMatches(
        captured: AXUIElement?,
        current: AXUIElement?
    ) -> Bool {
        switch (captured, current) {
        case let (.some(captured), .some(current)):
            return Self.focusIdentityMatches(
                identityEqual: CFEqual(captured, current),
                capturedPid: processIdentifier(of: captured),
                currentPid: processIdentifier(of: current),
                capturedRole: role(of: captured),
                currentRole: role(of: current)
            )
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success else {
            return nil
        }
        return roleValue as? String
    }
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalFlowApp/TextInsertionService.swift Tests/LocalFlowAppTests/TextInsertionServiceTests.swift
git commit -m "fix: match regenerated Chromium AX elements by pid and role"
```

---

### Task 5: Final verification and install

**Files:** none (build/install only)

- [ ] **Step 1: Run the complete test suite one final time**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS, zero failures.

- [ ] **Step 2: Build and install the app**

```bash
cd /Users/isidore/dev/localflow
./Scripts/install_app.sh
```

Expected: `Build complete!` then `/Applications/LocalFlow.app`; the app relaunches.

- [ ] **Step 3: Verify launch health in the log**

```bash
tail -6 ~/Library/Application\ Support/LocalFlow/localflow.log
```

Expected: a fresh `Launch appPath=...` line with the new commit hash, `Initial hotkey start started=true`, no error lines.

- [ ] **Step 4: Report for live validation**

The definitive validation is manual: the user dictates several consecutive times into Claude Desktop and we check the log shows `Paste confirmed`/`Paste finished` (and possibly `Keyboard paste retry`) with no `unconfirmed` losses.
