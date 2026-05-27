# LocalFlow

LocalFlow is a local macOS dictation app inspired by Wispr Flow. It records audio when you hold a global hotkey, sends the finished recording to OpenAI transcription, then pastes the cleaned text into the currently active app.

## V1 features

- Native macOS menu bar app.
- Floating recording/processing bar.
- LocalFlow interface with settings, history and dictionary tabs.
- Hold-to-talk hotkey: `Fn` first, with `Option+Space` fallback.
- Toggle hotkey: `Fn+Space`.
- Local temporary audio recording, deleted after transcription.
- OpenAI transcription with French defaults and mixed English vocabulary support.
- Optional OpenAI polish pass, disabled by default.
- App-aware prompt hints for Terminal/Codex, Cursor, WhatsApp and Telegram.
- Local editable dictionary and replacement rules.
- Automatic paste into the active app through a temporary clipboard.
- Local text-only history with retention pruning.

## Install from source

Prerequisites:

- macOS 13 or later.
- Xcode or Xcode Command Line Tools.
- An OpenAI API key.

Clone the repository, then create a local `.env` file:

```bash
git clone <repo-url> LocalFlow
cd LocalFlow
cp .env.example .env
```

Edit `.env` and set your own key:

```text
OPENAI_API_KEY=sk-your-key
```

Optionally copy the example dictionary and add your own terms:

```bash
cp Config/dictionary.example.json Config/dictionary.json
```

Install LocalFlow into `/Applications`:

```bash
./Scripts/install_app.sh
```

The install script builds the app, copies it to `/Applications/LocalFlow.app`, removes any stale `~/Applications/LocalFlow.app`, then launches the installed app.

On first install, if the repository contains `.env` and the runtime config does not exist yet, the script copies:

```text
~/LocalFlow/.env
```

to:

```text
~/Library/Application Support/LocalFlow/.env
```

The `.env` file is not copied into `/Applications/LocalFlow.app`.

Alternative: you can install first, then open `LF > Open LocalFlow > Settings`, paste your OpenAI key there, and click `Save Settings`. This creates or updates:

```text
~/Library/Application Support/LocalFlow/.env
```

For a user-local install instead of a global install:

```bash
./Scripts/install_app.sh ~/Applications
```

## Permissions

The first launch will require Microphone permission. Automatic paste requires Accessibility permission. `Fn` and other global key listeners require Input Monitoring permission.

If macOS does not show the Accessibility prompt, open:

```text
System Settings > Privacy & Security > Accessibility
```

Then enable LocalFlow. If it appears twice after rebuilds, remove the old entry and add the latest app bundle again.

Also open:

```text
System Settings > Privacy & Security > Input Monitoring
```

Enable LocalFlow there too if `Fn` does nothing while the app is running. `Option+Space` is registered through the Carbon hotkey API as a reliable fallback, but `Fn` still needs Input Monitoring.

## Usage

- Hold `Fn` to record, then release to transcribe and paste.
- If `Fn` conflicts with macOS, hold `Option+Space`.
- Press `Fn+Space` to start/stop toggle recording.
- While holding `Fn`, press `Space` to lock the current hold recording into toggle mode.
- Use the menu bar icon for manual start/stop, polish mode, opening LocalFlow and quitting.
- Edit settings from `LF > Open LocalFlow > Settings`, or edit `~/Library/Application Support/LocalFlow/.env`, then use `Diagnostics > Reload Config and Dictionary` or restart the app.
- Edit `~/Library/Application Support/LocalFlow/dictionary.json`, then use `Diagnostics > Reload Config and Dictionary`.
- `Config/dictionary.json` is the project-side fallback copied into the app bundle during build.

## Settings

Menu bar items:

- `Start Recording` / `Stop Recording`: manual recording control.
- `Polish Dictation`: toggles the optional post-processing pass for the current session.
- `Open LocalFlow`: opens the graphical interface.
- `Quit LocalFlow`: quits the background app.

## Graphical interface

Open it from `LF > Open LocalFlow`.

- `Settings`: edit the OpenAI key, models, language, hotkeys, polish, clipboard restore and history retention.
- `History`: browse recent dictated messages, inspect raw/final text, copy any item with its row-level `Copy` button, or clear local history.
- `Dictionary`: edit vocabulary terms and replacement rules. Terms are one per line. Replacements use `spoken phrase = final text`.
- `Diagnostics`: inspect hotkey status, permissions, file paths, logs and reload config/dictionary without rebuilding.

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

- `.env` for local config and `OPENAI_API_KEY`.
- `dictionary.json` for terms and replacement rules.
- `history.jsonl` for text-only dictation history.
- `localflow.log` for diagnostics.

Audio files are temporary and removed after processing.

Do not edit files inside `/Applications/LocalFlow.app` directly. That app bundle is replaced on every install. Editable user data belongs in `~/Library/Application Support/LocalFlow/`.

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

Live transcription requires a valid `OPENAI_API_KEY` in `~/Library/Application Support/LocalFlow/.env`.

## Troubleshooting

- No text is pasted after transcription: check Accessibility permission.
- Recording fails immediately: check Microphone permission.
- `Fn` does nothing: enable LocalFlow in `System Settings > Privacy & Security > Input Monitoring`, then open `LF > Open LocalFlow > Diagnostics` and click `Retry Hotkeys`, or restart LocalFlow.
- After pressing `Fn`, open `LF > Open LocalFlow > Diagnostics` and check `Last hotkey`. `Fn via HID` means LocalFlow caught it through the low-level listener; if it still says `none`, macOS did not deliver the key event to LocalFlow.
- `Option+Space` does nothing: open `LF > Open LocalFlow > Diagnostics` and check the hotkey status or diagnostic log.
- OpenAI error appears in the floating bar: check `OPENAI_API_KEY`, model names and network access.
- Clipboard content changes briefly: this is expected; LocalFlow restores it after paste by default.
- If macOS shows LocalFlow as enabled but LocalFlow still reports missing permission, remove the old LocalFlow entry from that permission pane, run `./Scripts/install_app.sh`, and add `/Applications/LocalFlow.app` again.
- Diagnostics are written to `~/Library/Application Support/LocalFlow/localflow.log`.
