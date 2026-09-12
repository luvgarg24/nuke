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
