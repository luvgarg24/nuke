# NUKE

A tiny, native macOS storage cleaner that tells you what is eating your disk before it deletes anything.

**Local by design.** No account, analytics, telemetry, uploads, or network service.

## MVP

- Native SwiftUI macOS app
- Scans known regenerable junk from Chrome, Claude, Adobe, Codex, Homebrew and Yarn
- Finds other unusually large cache directories for review
- Separates findings into **NUKE**, **REVIEW**, and **KEEP**
- Shows the exact filesystem path and explanation for every finding
- One-click deletion is limited to rules explicitly marked regenerable
- Review items are never automatically deleted
- Optional Full Disk Access explainer and shortcut to macOS Privacy settings
- Reveal any finding in Finder
- Detects a cable-connected, trusted iPhone through Image Capture Core
- Catalogues exposed photos and videos, sorted largest-first
- Filters iPhone media by photo or video and supports individual multi-selection
- Deletes selected iPhone media only after an explicit destructive confirmation

## iPhone support

Connect an unlocked iPhone by cable and trust the Mac when iOS asks. NUKE uses Apple's public `ImageCaptureCore` framework to read the photo/video catalogue exposed by the device, including file sizes, dimensions, duration, dates, and thumbnails.

iOS does **not** expose private app containers, app caches, or arbitrary “On My iPhone” documents to third-party Mac apps over USB. NUKE does not use private `MobileDevice` APIs to bypass that boundary. The iPhone feature therefore covers the camera-roll media that Apple's public API makes available.

## Run

Requires macOS 14+ and Xcode/Swift 6 tooling.

```sh
git clone https://github.com/luvgarg24/nuke.git
cd nuke
swift run NUKE
```

For a normal distributable `.app`, open `Package.swift` in Xcode and build the NUKE executable for macOS. A signed/notarized Xcode app target and DMG packaging are the next release step.

## Safety model

**NUKE**: known regenerable cache/log/model data. Eligible for one-click removal.

**REVIEW**: potentially useful or unknown data. NUKE will not automatically delete it.

**KEEP**: important/non-cleanable data. Reserved for storage explanation and future deep-scan results.

The scanner intentionally starts conservative. A storage cleaner should prefer missing junk over deleting someone's work.
