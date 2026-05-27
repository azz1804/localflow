# LocalFlow

LocalFlow is a local macOS dictation app inspired by Wispr Flow. It records audio when you hold a global hotkey, sends the finished recording to OpenAI transcription, then pastes the cleaned text into the currently active app.

## V1 features

- Native macOS menu bar app.
- Floating recording/processing bar.
- LocalFlow interface with settings, history and dictionary tabs.
- Hold-to-talk hotkey: `Fn` first, with `Option+Space` fallback.
- Toggle hotkey: `Control+Option+Space`.
- Local temporary audio recording, deleted after transcription.
- OpenAI transcription with French defaults and mixed English vocabulary support.
- Optional OpenAI polish pass, disabled by default.
- App-aware prompt hints for Terminal/Codex, Cursor, WhatsApp and Telegram.
- Local editable dictionary and replacement rules.
- Automatic paste into the active app through a temporary clipboard.
- Local text-only history with retention pruning.

## Setup

1. Copy `.env.example` to `.env`.
2. Set `OPENAI_API_KEY`.
3. Optionally copy `Config/dictionary.example.json` to `Config/dictionary.json` and edit your terms.
4. Build the app:

```bash
./Scripts/build_app.sh
```

5. Run it:

```bash
./Scripts/run_app.sh
```

The first launch will require Microphone permission. Automatic paste requires Accessibility permission. `Fn` and other global key listeners require Input Monitoring permission. If macOS does not show the Accessibility prompt, open:

```text
System Settings > Privacy & Security > Accessibility
```

Then enable LocalFlow. If it appears twice after rebuilds, remove the old entry and add the latest app bundle again.

```text
System Settings > Privacy & Security > Input Monitoring
```

Enable LocalFlow there too if `Fn` does nothing while the app is running. `Option+Space` is registered through the Carbon hotkey API as a reliable fallback, but `Fn` still needs Input Monitoring.

To install or update the app in `/Applications`, use the install script. It quits any running LocalFlow process before replacing the bundle:

```bash
./Scripts/install_app.sh
```

When installing to `/Applications`, the script also removes `~/Applications/LocalFlow.app` so Spotlight does not launch an older duplicate.

For a user-local install:

```bash
./Scripts/install_app.sh ~/Applications
```

## Usage

- Hold `Fn` to record, then release to transcribe and paste.
- If `Fn` conflicts with macOS, hold `Option+Space`.
- Press `Control+Option+Space` to start/stop toggle recording.
- Use the menu bar icon for manual start/stop, settings, support folder and quit.
- Edit `.env`, then use `Reload .env and Dictionary` from the menu bar or restart the app.
- Edit `~/Library/Application Support/LocalFlow/dictionary.json`, then use `Reload .env and Dictionary`.
- `Config/dictionary.json` is the project-side fallback copied into the app bundle during build.

## Settings

Menu bar items:

- `Start Recording` / `Stop Recording`: manual recording control.
- `Polish Dictation`: toggles the optional post-processing pass for the current session.
- `Open LocalFlow`: opens the graphical interface.
- `Reload .env and Dictionary`: reloads config, dictionary and hotkeys without rebuilding.
- `Open Support Folder`: opens the runtime folder that contains `dictionary.json` and `history.jsonl`.
- `Hotkeys: Active`: confirms the global keyboard hook is running.
- `Last hotkey`: shows the latest real hotkey event LocalFlow received, including whether it came from `Fn` or `Option+Space`.
- `Fn blocked - Enable Input Monitoring`: LocalFlow can run, but macOS is blocking the `Fn` listener.
- `Hotkeys: Inactive - Retry`: retries installing the global keyboard hook.
- `Request Accessibility Permission`: triggers the macOS permission prompt again.
- `Request Input Monitoring Permission`: triggers the macOS keyboard-listener permission prompt.
- `Open Diagnostic Log`: opens the runtime log used to debug hotkey, recording, transcription and paste events.

## Graphical interface

Open it from `LF > Open LocalFlow`.

- `Settings`: edit the OpenAI key, models, language, hotkeys, polish, clipboard restore and history retention.
- `History`: browse recent dictated messages, inspect raw/final text, copy any item with its row-level `Copy` button, or clear local history.
- `Dictionary`: edit vocabulary terms and replacement rules. Terms are one per line. Replacements use `spoken phrase = final text`.

Settings are saved to:

```text
~/Library/Application Support/LocalFlow/.env
```

Dictionary edits are saved to:

```text
~/Library/Application Support/LocalFlow/dictionary.json
```

## Local data

At runtime, LocalFlow stores editable/runtime data in:

```text
~/Library/Application Support/LocalFlow/
```

Files:

- `.env` if you choose to place config there.
- `dictionary.json` for terms and replacement rules.
- `history.jsonl` for text-only dictation history.

Audio files are temporary and removed after processing.

## Testing

```bash
swift test
./Scripts/build_app.sh
./Scripts/doctor.sh
```

Manual smoke test:

1. Open TextEdit first. Put the cursor in a blank document.
2. Hold `Fn`, say: `Bonjour Codex, peux-tu m'aider à écrire un message WhatsApp ?`, then release.
3. If `Fn` does nothing, use `Option+Space`.
4. Confirm the floating bar shows `Recording`, then `Processing`, then `Pasted`.
5. Confirm the text appears at the cursor.
6. Open Terminal or Cursor and repeat with a technical prompt.
7. Open `LF > Open LocalFlow > History` and confirm the text-only record appears.
8. Click the row-level `Copy` button and confirm the full generated text is copied.
9. Open `Dictionary`, add `code ex = Codex` to replacements, save, dictate `code ex`, and confirm the pasted output uses `Codex`.

## Verification performed during development

- `swift test`: 10 unit tests passing.
- `./Scripts/build_app.sh`: release `.app` bundle created.
- `plutil -lint`: generated `Info.plist` is valid.
- `codesign --verify --deep --strict`: ad-hoc signed bundle verifies.

Live transcription was not exercised here because no real `.env` with `OPENAI_API_KEY` is present in the workspace.

## Troubleshooting

- No text is pasted after transcription: check Accessibility permission.
- Recording fails immediately: check Microphone permission.
- `Fn` does nothing: enable LocalFlow in `System Settings > Privacy & Security > Input Monitoring`, then click `LF > Hotkeys: Inactive - Retry` or restart LocalFlow.
- After pressing `Fn`, open the menu and check `Last hotkey`. If it still says `none`, macOS did not deliver the key event to LocalFlow.
- `Option+Space` does nothing: open `LF > Hotkeys...` and check `~/Library/Application Support/LocalFlow/localflow.log`.
- OpenAI error appears in the floating bar: check `OPENAI_API_KEY`, model names and network access.
- Clipboard content changes briefly: this is expected; LocalFlow restores it after paste by default.
- If macOS shows LocalFlow as enabled but LocalFlow still reports missing permission, remove the old LocalFlow entry from that permission pane, run `./Scripts/install_app.sh`, and add `/Applications/LocalFlow.app` again.
- Diagnostics are written to `~/Library/Application Support/LocalFlow/localflow.log`.
