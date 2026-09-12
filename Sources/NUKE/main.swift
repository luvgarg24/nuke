import SwiftUI
import AppKit

@main
struct NukeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 820, height: 640)
    }
}

enum FindingKind: String, Sendable {
    case junk
    case review
}

struct Finding: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let what: String
    let consequence: String
    let path: String
    let bytes: Int64
    let kind: FindingKind
}

nonisolated func folderSize(_ path: String) -> Int64 {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
    if !isDirectory.boolValue {
        return (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: []
    ) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
            total += Int64(values.fileSize ?? 0)
        }
    }
    return total
}

@MainActor
final class Scanner: ObservableObject {
    @Published var findings: [Finding] = []
    @Published var scanning = false
    @Published var status = "Ready"
    @Published var lastFreed: Int64 = 0
    @Published var cleanupError: String?

    private let fm = FileManager.default
    private var home: String { fm.homeDirectoryForCurrentUser.path }

    var junkBytes: Int64 { findings.filter { $0.kind == .junk }.reduce(0) { $0 + $1.bytes } }
    var reviewBytes: Int64 { findings.filter { $0.kind == .review }.reduce(0) { $0 + $1.bytes } }

    func scan() {
        scanning = true
        status = "Scanning…"
        lastFreed = 0
        cleanupError = nil
        let h = home

        Task.detached(priority: .userInitiated) {
            let rules: [(String, String, String, String, FindingKind)] = [
                ("Google Chrome cache", "Temporary files Chrome keeps to load pages faster.", "Chrome recreates these as you browse.", "\(h)/Library/Caches/Google", .junk),
                ("Chrome local model", "A model Chrome downloaded for features that run on your Mac.", "Chrome may download it again if a feature needs it.", "\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .junk),
                ("Chrome Default website data", "Offline copies and background data saved by websites in your main Chrome profile.", "Sites can rebuild this. Offline site data may disappear.", "\(h)/Library/Application Support/Google/Chrome/Default/Service Worker", .junk),
                ("Chrome Profile 1 website data", "Offline copies and background data saved by websites in Chrome Profile 1.", "Sites can rebuild this. Offline site data may disappear.", "\(h)/Library/Application Support/Google/Chrome/Profile 1/Service Worker", .junk),
                ("Chrome Profile 2 website data", "Offline copies and background data saved by websites in Chrome Profile 2.", "Sites can rebuild this. Offline site data may disappear.", "\(h)/Library/Application Support/Google/Chrome/Profile 2/Service Worker", .junk),
                ("Claude local VM", "A local virtual environment downloaded by Claude for computer features.", "Claude can download it again when needed.", "\(h)/Library/Application Support/Claude/vm_bundles", .junk),
                ("Claude cache", "Temporary files created while using Claude.", "Claude recreates them automatically.", "\(h)/Library/Application Support/Claude/Cache", .junk),
                ("Claude code cache", "Compiled interface files used to make Claude launch faster.", "Claude recreates them automatically.", "\(h)/Library/Application Support/Claude/Code Cache", .junk),
                ("Adobe logs", "Diagnostic records written by Adobe apps.", "Your Photoshop files and projects are not here.", "\(h)/Library/Logs/Adobe", .junk),
                ("Creative Cloud logs", "Diagnostic records written by Creative Cloud.", "Creative Cloud can create new logs later.", "\(h)/Library/Logs/CreativeCloud", .junk),
                ("Codex cache", "Temporary files Codex keeps on your Mac.", "Codex recreates them when needed.", "\(h)/Library/Caches/com.openai.codex", .junk),
                ("Homebrew cache", "Installers and packages Homebrew already downloaded.", "Homebrew downloads them again if needed.", "\(h)/Library/Caches/Homebrew", .junk),
                ("Yarn cache", "Packages Yarn downloaded during development.", "Yarn downloads them again if needed.", "\(h)/Library/Caches/Yarn", .junk),
                ("Downloads", "Everything currently inside your Downloads folder.", "These are your files. Open the folder and choose deliberately.", "\(h)/Downloads", .review)
            ]

            var output: [Finding] = []
            for rule in rules {
                let size = folderSize(rule.3)
                if size > 0 {
                    output.append(Finding(name: rule.0, what: rule.1, consequence: rule.2, path: rule.3, bytes: size, kind: rule.4))
                }
            }

            let cacheRoot = "\(h)/Library/Caches"
            if let children = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot) {
                let known = Set(output.map { $0.path })
                for child in children {
                    let path = cacheRoot + "/" + child
                    if known.contains(path) { continue }
                    let size = folderSize(path)
                    if size >= 250_000_000 {
                        output.append(Finding(
                            name: child,
                            what: "A large cache created by an application on your Mac.",
                            consequence: "NUKE doesn't know this cache well enough to preselect it. Review it first.",
                            path: path,
                            bytes: size,
                            kind: .review
                        ))
                    }
                }
            }

            output.sort { $0.bytes > $1.bytes }
            await MainActor.run {
                self.findings = output
                self.scanning = false
                self.status = "Scan complete"
            }
        }
    }

    func delete(_ targets: [Finding]) {
        var freed: Int64 = 0
        var failures: [String] = []
        for target in targets {
            do {
                try fm.removeItem(atPath: target.path)
                freed += target.bytes
            } catch {
                failures.append(target.name)
            }
        }
        lastFreed = freed
        cleanupError = failures.isEmpty ? nil : "Couldn’t remove: " + failures.joined(separator: ", ")
        scan()
    }

    func reveal(_ finding: Finding) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)])
    }
}

enum ResultsView: String, CaseIterable, Identifiable {
    case cleanup = "Clean up"
    case review = "Review"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var section: ResultsView = .cleanup
    @State private var selected = Set<UUID>()
    @State private var showingPrivacy = false
    @State private var confirmingDelete = false

    private var visibleFindings: [Finding] {
        scanner.findings.filter { section == .cleanup ? $0.kind == .junk : $0.kind == .review }
    }

    private var selectedFindings: [Finding] {
        scanner.findings.filter { selected.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedFindings.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            navigation
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showingPrivacy = true } label: { Label("Privacy", systemImage: "hand.raised") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: runScan) { Label(scanner.scanning ? "Scanning…" : "Scan", systemImage: "arrow.clockwise") }
                    .disabled(scanner.scanning)
            }
        }
        .sheet(isPresented: $showingPrivacy) { PrivacyView() }
        .confirmationDialog("Nuke selected data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Nuke \(formatted(selectedBytes))", role: .destructive) {
                scanner.delete(selectedFindings)
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(section == .review
                 ? "You selected this data manually. It may not be automatically recoverable."
                 : "NUKE selected known disposable data. Apps may recreate or download some of it later.")
        }
        .onChange(of: section) { _, _ in selected.removeAll() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                if scanner.findings.isEmpty {
                    Text("Find what's taking up space")
                        .font(.system(size: 28, weight: .semibold))
                    Text("NUKE finds disposable app data and large folders worth checking.")
                        .foregroundStyle(.secondary)
                } else if section == .cleanup {
                    Text("\(formatted(scanner.junkBytes)) of disposable data")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Caches, logs and downloaded app data that can be recreated.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(formatted(scanner.reviewBytes)) needs your call")
                        .font(.system(size: 28, weight: .semibold))
                    Text("NUKE found it, but won't decide for you. Select only what you want gone.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if scanner.findings.isEmpty {
                Button("Scan Mac", action: runScan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(scanner.scanning)
            } else {
                Button(selected.isEmpty ? "Select items" : "Nuke \(formatted(selectedBytes))…") {
                    if selected.isEmpty { selectRecommended() } else { confirmingDelete = true }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(scanner.scanning || visibleFindings.isEmpty)
            }
        }
        .padding(28)
    }

    private var navigation: some View {
        HStack(spacing: 14) {
            Picker("", selection: $section) {
                Text("Clean up  \(formatted(scanner.junkBytes))").tag(ResultsView.cleanup)
                Text("Review  \(formatted(scanner.reviewBytes))").tag(ResultsView.review)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)

            Spacer()

            if !visibleFindings.isEmpty {
                Button(selected.count == visibleFindings.count ? "Deselect All" : "Select All") {
                    if selected.count == visibleFindings.count {
                        selected.removeAll()
                    } else {
                        selected = Set(visibleFindings.map(\.id))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    @ViewBuilder private var results: some View {
        if scanner.findings.isEmpty && !scanner.scanning {
            ContentUnavailableView("Ready to scan", systemImage: "internaldrive", description: Text("Nothing is uploaded. The scan happens on this Mac."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scanner.scanning && scanner.findings.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking app data and caches…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleFindings.isEmpty {
            ContentUnavailableView(section == .cleanup ? "Nothing to clean" : "Nothing needs review", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visibleFindings) { finding in
                FindingRow(
                    finding: finding,
                    isSelected: selected.contains(finding.id),
                    toggle: { toggle(finding) },
                    reveal: { scanner.reveal(finding) }
                )
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
            Text("Local scan. Nothing uploaded.")
            Spacer()
            if !selected.isEmpty { Text("\(selected.count) selected · \(formatted(selectedBytes))") }
            else { Text(scanner.status) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private func runScan() {
        selected.removeAll()
        scanner.scan()
    }

    private func toggle(_ finding: Finding) {
        if selected.contains(finding.id) { selected.remove(finding.id) }
        else { selected.insert(finding.id) }
    }

    private func selectRecommended() {
        if section == .cleanup { selected = Set(visibleFindings.map(\.id)) }
    }
}

struct FindingRow: View {
    let finding: Finding
    let isSelected: Bool
    let toggle: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(finding.name).fontWeight(.medium)
                    Spacer()
                    Text(formatted(finding.bytes)).monospacedDigit().fontWeight(.medium)
                }
                Text(finding.what)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.consequence)
                    .font(.caption)
                    .foregroundStyle(finding.kind == .review ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(finding.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Button("Show in Finder", action: reveal)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
            Text("Your files stay yours.")
                .font(.title2).fontWeight(.semibold)
            Text("NUKE scans storage locally. It doesn't upload your files or require an account. Full Disk Access is optional and only helps NUKE inspect protected locations.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { dismiss() }
                Spacer()
                Button("Open Full Disk Access…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}

private func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
