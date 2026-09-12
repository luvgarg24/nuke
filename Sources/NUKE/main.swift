import SwiftUI
import AppKit

@main
struct NukeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 1040, height: 700)
    }
}

enum FindingKind: String, Sendable { case nuke, review }

enum Page: String, CaseIterable, Identifiable {
    case nuking = "Nuking"
    case review = "Review"
    case ignored = "Ignored"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .nuking: return "trash"
        case .review: return "eye"
        case .ignored: return "folder"
        }
    }
}

struct Finding: Identifiable, Hashable, Sendable {
    let id: String
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
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
           values.isRegularFile == true {
            total += Int64(values.fileSize ?? 0)
        }
    }
    return total
}

@MainActor
final class Scanner: ObservableObject {
    @Published var findings: [Finding] = []
    @Published var scanning = false
    @Published var status = "Not scanned"
    @Published var hasScanned = false

    private let fm = FileManager.default
    private var home: String { fm.homeDirectoryForCurrentUser.path }

    func scan() {
        scanning = true
        status = "Scanning your Mac…"
        let h = home

        Task.detached(priority: .userInitiated) {
            // v1 is deliberately whitelist-only. Never crawl arbitrary Library,
            // media, Downloads, Documents, Mail, Messages or other TCC locations.
            let rules: [(String, String, String, String, FindingKind)] = [
                ("Google Chrome cache", "Temporary browser files.", "Chrome rebuilds these as you browse.", "\(h)/Library/Caches/Google", .nuke),
                ("Chrome local model", "A model Chrome downloaded to run features on your Mac.", "Chrome may download it again if it needs it.", "\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .nuke),
                ("Chrome Default website data", "Offline copies and background data saved by websites.", "Sites rebuild it; offline site data may be lost.", "\(h)/Library/Application Support/Google/Chrome/Default/Service Worker", .nuke),
                ("Chrome Profile 1 website data", "Offline copies and background data saved by websites in Profile 1.", "Sites rebuild it; offline site data may be lost.", "\(h)/Library/Application Support/Google/Chrome/Profile 1/Service Worker", .nuke),
                ("Chrome Profile 2 website data", "Offline copies and background data saved by websites in Profile 2.", "Sites rebuild it; offline site data may be lost.", "\(h)/Library/Application Support/Google/Chrome/Profile 2/Service Worker", .nuke),
                ("Claude local VM", "Claude's downloaded local computer environment.", "Claude can download a fresh copy when needed.", "\(h)/Library/Application Support/Claude/vm_bundles", .nuke),
                ("Claude cache", "Temporary files Claude leaves behind.", "Claude recreates it.", "\(h)/Library/Application Support/Claude/Cache", .nuke),
                ("Claude code cache", "Compiled interface files used to speed up Claude.", "Claude recreates it.", "\(h)/Library/Application Support/Claude/Code Cache", .nuke),
                ("Adobe logs", "Diagnostic records from Adobe apps. Not your projects.", "Adobe writes new logs when needed.", "\(h)/Library/Logs/Adobe", .nuke),
                ("Creative Cloud logs", "Diagnostic records from Creative Cloud.", "Creative Cloud writes new logs later.", "\(h)/Library/Logs/CreativeCloud", .nuke),
                ("Codex cache", "Temporary files Codex keeps locally.", "Codex recreates it.", "\(h)/Library/Caches/com.openai.codex", .nuke),
                ("Homebrew cache", "Installers and packages Homebrew already downloaded.", "Homebrew downloads them again if required.", "\(h)/Library/Caches/Homebrew", .nuke),
                ("Yarn cache", "Packages Yarn downloaded while installing dependencies.", "Yarn downloads them again if required.", "\(h)/Library/Caches/Yarn", .nuke)
            ]

            var output: [Finding] = []
            for rule in rules {
                let size = folderSize(rule.3)
                if size > 0 {
                    output.append(Finding(id: rule.3, name: rule.0, what: rule.1, consequence: rule.2, path: rule.3, bytes: size, kind: rule.4))
                }
            }

            output.sort { $0.bytes > $1.bytes }
            await MainActor.run {
                self.findings = output
                self.scanning = false
                self.hasScanned = true
                self.status = "Scan complete"
            }
        }
    }

    func delete(_ targets: [Finding]) {
        for target in targets { try? fm.removeItem(atPath: target.path) }
        scan()
    }

    func reveal(_ finding: Finding) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)])
    }
}

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var page: Page? = .nuking
    @State private var selected = Set<String>()
    @State private var showingPrivacy = false
    @State private var confirmingDelete = false
    @AppStorage("ignoredPaths") private var ignoredStore = ""
    @AppStorage("excludedNukePaths") private var excludedStore = ""

    private var ignored: Set<String> { Set(ignoredStore.split(separator: "\n").map(String.init)) }
    private var excluded: Set<String> { Set(excludedStore.split(separator: "\n").map(String.init)) }
    private var activePage: Page { page ?? .nuking }
    private var nukeItems: [Finding] { scanner.findings.filter { $0.kind == .nuke && !ignored.contains($0.path) } }
    private var reviewItems: [Finding] { scanner.findings.filter { $0.kind == .review && !ignored.contains($0.path) } }
    private var ignoredItems: [Finding] { scanner.findings.filter { ignored.contains($0.path) } }
    private var visible: [Finding] {
        switch activePage {
        case .nuking: return nukeItems
        case .review: return reviewItems
        case .ignored: return ignoredItems
        }
    }
    private var selectedItems: [Finding] { scanner.findings.filter { selected.contains($0.path) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    private var nukeBytes: Int64 { nukeItems.reduce(0) { $0 + $1.bytes } }
    private var reviewBytes: Int64 { reviewItems.reduce(0) { $0 + $1.bytes } }
    private var ignoredBytes: Int64 { ignoredItems.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: runScan) {
                    Label(scanner.scanning ? "Scanning…" : "Scan", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.scanning)
            }
        }
        .sheet(isPresented: $showingPrivacy) { PrivacyView() }
        .confirmationDialog("Nuke \(formatted(selectedBytes))?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Nuke \(formatted(selectedBytes))", role: .destructive) {
                scanner.delete(selectedItems)
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: page) { _, _ in syncSelection() }
        .onChange(of: scanner.findings) { _, _ in syncSelection() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NUKE").font(.system(size: 22, weight: .bold))
                Text("Free up space on your Mac.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)

            List(selection: $page) {
                Label { HStack { Text("Nuking"); Spacer(); if scanner.hasScanned { Text(formatted(nukeBytes)).foregroundStyle(.secondary) } } } icon: { Image(systemName: Page.nuking.icon) }.tag(Page.nuking)
                Label { HStack { Text("Review"); Spacer(); if scanner.hasScanned { Text(formatted(reviewBytes)).foregroundStyle(.secondary) } } } icon: { Image(systemName: Page.review.icon) }.tag(Page.review)
                Label { HStack { Text("Ignored"); Spacer(); if scanner.hasScanned { Text(formatted(ignoredBytes)).foregroundStyle(.secondary) } } } icon: { Image(systemName: Page.ignored.icon) }.tag(Page.ignored)
            }
            .listStyle(.sidebar)

            Spacer()
            Button { showingPrivacy = true } label: { Label("Privacy", systemImage: "hand.raised") }
                .buttonStyle(.plain)
                .padding(16)
        }
    }

    private var detail: some View {
        ZStack {
            VStack(spacing: 0) {
                if !scanner.hasScanned && !scanner.scanning {
                    welcome
                } else {
                    pageHeader
                    if activePage == .nuking && !visible.isEmpty { stats }
                    itemList
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            if scanner.scanning { scanOverlay }
        }
    }

    private var scanOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.94).ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView().controlSize(.large)
                Text("Scanning your Mac…").font(.title2).fontWeight(.semibold)
                Text("Looking through known caches and temporary app data.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView().progressViewStyle(.linear).frame(width: 300)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("See what's eating your Mac.").font(.system(size: 30, weight: .semibold))
            Text("Scan known caches and temporary app data. No extra access needed.").foregroundStyle(.secondary)
            Button("Scan Mac", action: runScan).buttonStyle(.borderedProminent).controlSize(.large)
            Label("Scans locally. Nothing is uploaded.", systemImage: "lock.fill").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageHeader: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                if activePage == .nuking {
                    Text("\(formatted(nukeBytes)) worth nuking.").font(.system(size: 34, weight: .semibold))
                    Text("Temporary data apps can recreate. Pre-selected for you.").foregroundStyle(.secondary)
                } else if activePage == .review {
                    Text("\(formatted(reviewBytes)) needs your call.").font(.system(size: 34, weight: .semibold))
                    Text("NUKE won't touch this unless you choose it.").foregroundStyle(.secondary)
                } else {
                    Text("\(formatted(ignoredBytes)) ignored.").font(.system(size: 34, weight: .semibold))
                    Text("NUKE leaves these alone.").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if activePage != .ignored && !selected.isEmpty {
                Button("Nuke \(formatted(selectedBytes))") { confirmingDelete = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(28)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            Stat(icon: "checkmark.square", value: "\(selected.count)", label: "selected")
            Divider().frame(height: 42)
            Stat(icon: "internaldrive", value: formatted(selectedBytes), label: "will be freed")
            Divider().frame(height: 42)
            Stat(icon: "arrow.clockwise", value: "Recreatable", label: "apps can rebuild it")
        }
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder private var itemList: some View {
        if visible.isEmpty {
            ContentUnavailableView(activePage == .ignored ? "Nothing ignored" : "Nothing here", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if activePage != .ignored {
                    HStack {
                        Button(action: toggleAll) { Image(systemName: allVisibleSelected ? "checkmark.square.fill" : "square") }
                            .buttonStyle(.borderless)
                        Text(activePage == .nuking ? "Auto-select all" : "Select all")
                        Spacer()
                        Text("\(visible.count) items").foregroundStyle(.secondary)
                    }
                }
                ForEach(visible) { finding in
                    FindingRow(
                        finding: finding,
                        selected: selected.contains(finding.path),
                        page: activePage,
                        toggle: { toggle(finding) },
                        reveal: { scanner.reveal(finding) },
                        ignore: { ignore(finding) },
                        restore: { restore(finding) }
                    )
                }
            }
            .listStyle(.inset)
        }
    }

    private var allVisibleSelected: Bool { !visible.isEmpty && visible.allSatisfy { selected.contains($0.path) } }
    private func runScan() { selected.removeAll(); scanner.scan() }
    private func syncSelection() {
        if activePage == .nuking { selected = Set(nukeItems.filter { !excluded.contains($0.path) }.map(\.path)) }
        else { selected.removeAll() }
    }
    private func toggle(_ finding: Finding) {
        if selected.contains(finding.path) {
            selected.remove(finding.path)
            if finding.kind == .nuke { var e = excluded; e.insert(finding.path); excludedStore = e.sorted().joined(separator: "\n") }
        } else {
            selected.insert(finding.path)
            if finding.kind == .nuke { var e = excluded; e.remove(finding.path); excludedStore = e.sorted().joined(separator: "\n") }
        }
    }
    private func toggleAll() {
        if allVisibleSelected { for finding in visible { selected.remove(finding.path) } }
        else { for finding in visible { selected.insert(finding.path) } }
    }
    private func ignore(_ finding: Finding) {
        var x = ignored
        x.insert(finding.path)
        ignoredStore = x.sorted().joined(separator: "\n")
        selected.remove(finding.path)
    }
    private func restore(_ finding: Finding) {
        var x = ignored
        x.remove(finding.path)
        ignoredStore = x.sorted().joined(separator: "\n")
    }
}

struct Stat: View {
    let icon: String, value: String, label: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(value).fontWeight(.semibold)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct FindingRow: View {
    let finding: Finding
    let selected: Bool
    let page: Page
    let toggle: () -> Void
    let reveal: () -> Void
    let ignore: () -> Void
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if page != .ignored {
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.borderless)
                .frame(width: 26)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(finding.name).fontWeight(.medium)
                Text(finding.what).font(.caption).foregroundStyle(.secondary)
                Text(finding.consequence).font(.caption).foregroundStyle(.tertiary)
                Text(shortPath(finding.path))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatted(finding.bytes))
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .frame(width: 112, alignment: .trailing)

            Menu {
                Button("Show in Finder", action: reveal)
                if page == .ignored {
                    Button("Stop Ignoring", action: restore)
                } else {
                    Button("Ignore on future scans", action: ignore)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 36, alignment: .center)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if page != .ignored { toggle() } }
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "hand.raised.fill").font(.system(size: 30)).foregroundStyle(.blue)
            Text("Your files stay yours.").font(.title2).fontWeight(.semibold)
            Text("NUKE scans locally. It doesn't upload your files or require an account.").foregroundStyle(.secondary)
            Button("Done") { dismiss() }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(28)
        .frame(width: 440)
    }
}

private func shortPath(_ path: String) -> String {
    path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
}

private func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
