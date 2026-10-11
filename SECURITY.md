# Security Policy

## Threat Model

WhisperDictation is a macOS dictation app that requires two sensitive permissions: **Microphone** and **Accessibility**. Because of this, we take security seriously and have designed the app to minimize attack surface.

### What the app does

| Permission | What it's used for |
|-----------|-------------------|
| Microphone | Capture audio **only** while the user holds the configured hotkey. Audio is processed in RAM (16kHz mono Float32), fed to whisper.cpp for transcription, and discarded. Never written to disk. |
| Accessibility | Detect the global hotkey via `CGEvent.tapCreate`, and inject transcribed text at the cursor via `CGEvent.keyboardSetUnicodeString`. Does not read screen contents or other keystrokes. |

### What the app does NOT do

- No audio or transcription data leaves the device. Ever.
- No logging of transcribed text. Dictated content is never written to disk, Console.app, or the unified log — it is typed at the cursor and discarded.
- No telemetry, analytics, crash reporting, or any form of tracking.
- No automatic updates / update server.
- No account, license check, or any "phone home" behavior.
- No web content or external scripts (the app is 100% native Swift/SwiftUI).

> **Fork note:** this fork adds Custom Operations (see the top of the README), which changes two things from the upstream guarantees above:
> - **Clipboard access**: running an operation briefly copies the current text selection to read it, then restores whatever was previously on the clipboard. This happens only when the user presses an operation's own hotkey — never passively.
> - **Network requests**: in addition to Whisper model downloads from Hugging Face, this fork also fetches GGUF text-generation models from Hugging Face (same user-initiated download flow in Settings), and fetches a list of ready-made operation prompt templates from this fork's own GitHub repo (`operation-templates/templates.json` on `main`) — only when the user taps Refresh in Settings, never automatically or in the background. Both are listed below with the exact code locations.

## Auditability

You can verify every network-facing line in one command:

```bash
git clone https://github.com/helio4987/WhisperDictationAll.git
cd WhisperDictationAll
grep -rE "URLSession|URLRequest|http://|https://|NSURLConnection|Network\.framework" --include='*.swift' WhisperDictation/
```

`WhisperDictation/Utilities/WhisperLanguages.swift` matches too, but only inside a doc-comment citation link — no network call there. The actual network-making matches, all user-initiated (nothing fires automatically or in the background):
- `WhisperDictation/Engine/ModelManager.swift` — Whisper model downloads from Hugging Face, started when the user clicks "Download" in Settings > Primary/Secondary Language.
- `WhisperDictation/Engine/TextModelCatalog.swift`/`TextModelManager.swift` — GGUF text-generation model discovery and download from Hugging Face, started when the user taps Refresh / Download in Settings > Custom Operations.
- `WhisperDictation/Engine/OperationTemplateCatalog.swift` — fetches `operation-templates/templates.json` from this fork's own GitHub repo (raw content, `main` branch), only when the user taps Refresh in Settings > Custom Operations > Templates. Populates local prompt text fields only — nothing fetched this way is ever executed as code.

For clipboard access (new in this fork, used by Custom Operations), search instead for `NSPasteboard`:
```bash
grep -rn "NSPasteboard" --include='*.swift' WhisperDictation/
```
The only use is in `WhisperDictation/Engine/SelectionCapture.swift`, which reads the current selection (via a simulated Cmd+C) and restores the clipboard's prior contents immediately after — triggered only by the user pressing a Custom Operation's own hotkey.

We also recommend running a firewall like [Little Snitch](https://www.obdev.at/products/littlesnitch/) or [LuLu](https://objective-see.org/products/lulu.html) while testing the app. You will see zero outbound connections during normal use.

## Build from Source

Don't want to trust the pre-built DMG? Build from source:

```bash
git clone --recurse-submodules https://github.com/sam-pop/WhisperDictation.git
cd WhisperDictation
make whisper && make app
open build/WhisperDictation.app
```

The Makefile compiles directly via `xcrun swiftc` with no opaque build steps. You can read the entire pipeline in the [Makefile](Makefile).

## Dependencies

- **[whisper.cpp](https://github.com/ggerganov/whisper.cpp)** (git submodule) — C/C++ port of OpenAI Whisper. MIT licensed. Compiled as a static library, linked directly into the app. No dynamic libraries.
- **Whisper models** (downloaded on demand) — Pre-trained ML models from OpenAI, distributed via HuggingFace. MIT licensed.
- **macOS frameworks** (AVFoundation, Metal, CoreGraphics, AppKit, etc.) — First-party Apple frameworks.

No third-party Swift packages, no CocoaPods, no Carthage. The only external code is whisper.cpp and Apple's SDK.

## Code Signing

Releases are currently **ad-hoc signed** (not notarized by Apple). This means macOS Gatekeeper will show a warning on first launch. We document how to bypass this in the [install instructions](https://sam-pop.github.io/WhisperDictation/#install). Formal Developer ID notarization is planned once the project enrolls in the Apple Developer Program.

Every release DMG will include a SHA256 checksum in the release notes so you can verify integrity.

## Reporting a Vulnerability

If you discover a security issue, please **do not open a public issue**. Instead:

1. Email the maintainer directly (see [GitHub profile](https://github.com/sam-pop)), or
2. Open a [private security advisory](https://github.com/sam-pop/WhisperDictation/security/advisories/new) on GitHub

We aim to respond within 72 hours. Critical issues will be patched and disclosed on an accelerated timeline.

## Scope

In scope:
- Unintended network activity
- Privilege escalation via the Accessibility API
- Audio capture outside of the hotkey-held state
- Memory safety issues in our Swift code or bridging layer
- Supply chain concerns around whisper.cpp or model downloads

Out of scope:
- Vulnerabilities in whisper.cpp itself (please report to the [whisper.cpp project](https://github.com/ggerganov/whisper.cpp))
- Vulnerabilities in macOS or Apple frameworks
- Physical attacks requiring local user access

## Acknowledgments

Security researchers who responsibly disclose issues will be credited in release notes unless they prefer to remain anonymous.
