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
        switch self { case .nuking: return "trash"; case .review: return "eye"; case .ignored: return "folder" }
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
    guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
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
    @Published var cleanupError: String?

    private let fm = FileManager.default
    private var home: String { fm.homeDirectoryForCurrentUser.path }

    func scan() {
        scanning = true
        status = "Scanning…"
        cleanupError = nil
        let h = home

        Task.detached(priority: .userInitiated) {
            let rules: [(String, String, String, String, FindingKind)] = [
                ("Google Chrome cache", "Temporary browser files.", "Delete it. Chrome rebuilds it as you browse.", "\(h)/Library/Caches/Google", .nuke),
                ("Chrome local model", "A model Chrome downloaded to run features on your Mac.", "Delete it. Chrome may download it again if it needs it.", "\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .nuke),
                ("Chrome Default website data", "Offline copies and background data saved by websites.", "Delete it. Sites rebuild it; offline site data may be lost.", "\(h)/Library/Application Support/Google/Chrome/Default/Service Worker", .nuke),
                ("Chrome Profile 1 website data", "Offline copies and background data saved by websites in Profile 1.", "Delete it. Sites rebuild it; offline site data may be lost.", "\(h)/Library/Application Support/Google/Chrome/Profile 1/Service Worker", .nuke),
                ("Chrome Profile 2 website data", "Offline copies and background data saved by websites in Profile 2.", "Delete it. Sites rebuild it; offline site data may be lost.", "\(h)/Library/Application Support/Google/Chrome/Profile 2/Service Worker", .nuke),
                ("Claude local VM", "Claude's downloaded local computer environment.", "Delete it. Claude can download a fresh copy when needed.", "\(h)/Library/Application Support/Claude/vm_bundles", .nuke),
                ("Claude cache", "Temporary files Claude leaves behind.", "Delete it. Claude recreates it.", "\(h)/Library/Application Support/Claude/Cache", .nuke),
                ("Claude code cache", "Compiled interface files used to speed up Claude.", "Delete it. Claude recreates it.", "\(h)/Library/Application Support/Claude/Code Cache", .nuke),
                ("Adobe logs", "Diagnostic records from Adobe apps. Not your projects.", "Delete it. Adobe writes new logs when needed.", "\(h)/Library/Logs/Adobe", .nuke),
                ("Creative Cloud logs", "Diagnostic records from Creative Cloud.", "Delete it. Creative Cloud writes new logs later.", "\(h)/Library/Logs/CreativeCloud", .nuke),
                ("Codex cache", "Temporary files Codex keeps locally.", "Delete it. Codex recreates it.", "\(h)/Library/Caches/com.openai.codex", .nuke),
                ("Homebrew cache", "Installers and packages Homebrew already downloaded.", "Delete it. Homebrew downloads them again if required.", "\(h)/Library/Caches/Homebrew", .nuke),
                ("Yarn cache", "Packages Yarn downloaded while installing dependencies.", "Delete it. Yarn downloads them again if required.", "\(h)/Library/Caches/Yarn", .nuke),
                ("Downloads", "Your Downloads folder. These are your actual files.", "Your call. Open it first if you are unsure.", "\(h)/Downloads", .review)
            ]

            var output: [Finding] = []
            for r in rules {
                let size = folderSize(r.3)
                if size > 0 { output.append(Finding(id: r.3, name: r.0, what: r.1, consequence: r.2, path: r.3, bytes: size, kind: r.4)) }
            }

            let root = "\(h)/Library/Caches"
            if let children = try? FileManager.default.contentsOfDirectory(atPath: root) {
                let known = Set(output.map(\.path))
                for child in children {
                    let path = root + "/" + child
                    if known.contains(path) { continue }
                    let size = folderSize(path)
                    if size >= 250_000_000 {
                        output.append(Finding(id: path, name: friendlyName(child), what: "A large cache created by \(friendlyName(child)).", consequence: "Not auto-selected. Check the app or folder, then nuke it if you don't need the cached data.", path: path, bytes: size, kind: .review))
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
        var failures: [String] = []
        for target in targets {
            do { try fm.removeItem(atPath: target.path) }
            catch { failures.append(target.name) }
        }
        cleanupError = failures.isEmpty ? nil : "Couldn't remove: " + failures.joined(separator: ", ")
        scan()
    }

    func reveal(_ finding: Finding) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)]) }
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
        switch activePage { case .nuking: return nukeItems; case .review: return reviewItems; case .ignored: return ignoredItems }
    }
    private var selectedItems: [Finding] { scanner.findings.filter { selected.contains($0.path) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    private var nukeBytes: Int64 { nukeItems.reduce(0) { $0 + $1.bytes } }
    private var reviewBytes: Int64 { reviewItems.reduce(0) { $0 + $1.bytes } }
    private var ignoredBytes: Int64 { ignoredItems.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: runScan) { Label(scanner.scanning ? "Scanning…" : "Scan", systemImage: "arrow.clockwise") }
                    .disabled(scanner.scanning)
            }
        }
        .sheet(isPresented: $showingPrivacy) { PrivacyView() }
        .confirmationDialog("Nuke \(formatted(selectedBytes))?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Nuke \(formatted(selectedBytes))", role: .destructive) {
                scanner.delete(selectedItems)
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(activePage == .review ? "You picked these yourself. Some reviewed data may not come back automatically." : "These are the items currently selected for nuking.")
        }
        .onChange(of: page) { _, _ in syncSelection() }
        .onChange(of: scanner.findings) { _, _ in syncSelection() }
        .task { if scanner.findings.isEmpty { scanner.scan() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NUKE").font(.system(size: 22, weight: .bold))
                Text("Free up space on your Mac.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 20)

            List(selection: $page) {
                Label { HStack { Text("Nuking"); Spacer(); Text(formatted(nukeBytes)).foregroundStyle(.secondary) } } icon: { Image(systemName: Page.nuking.icon) }.tag(Page.nuking)
                Label { HStack { Text("Review"); Spacer(); Text(formatted(reviewBytes)).foregroundStyle(.secondary) } } icon: { Image(systemName: Page.review.icon) }.tag(Page.review)
                Label { HStack { Text("Ignored"); Spacer(); Text(formatted(ignoredBytes)).foregroundStyle(.secondary) } } icon: { Image(systemName: Page.ignored.icon) }.tag(Page.ignored)
            }
            .listStyle(.sidebar)

            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Button { showingPrivacy = true } label: { Label("Privacy", systemImage: "hand.raised") }.buttonStyle(.plain)
                Text("Local. Private. Yours.").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if scanner.scanning && scanner.findings.isEmpty {
                VStack(spacing: 12) { ProgressView(); Text("Finding what's eating your Mac…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pageHeader
                if activePage == .nuking && !visible.isEmpty { stats }
                itemList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                switch activePage {
                case .nuking:
                    Text("\(formatted(nukeBytes)) worth nuking.").font(.system(size: 34, weight: .semibold))
                    Text("Temporary files, caches and downloads apps can recreate. Pre-selected for you.").foregroundStyle(.secondary)
                case .review:
                    Text("\(formatted(reviewBytes)) needs your call.").font(.system(size: 34, weight: .semibold))
                    Text("Big folders NUKE won't touch unless you choose them.").foregroundStyle(.secondary)
                case .ignored:
                    Text("\(formatted(ignoredBytes)) ignored.").font(.system(size: 34, weight: .semibold))
                    Text("NUKE will leave these alone on future scans.").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if activePage != .ignored && !selected.isEmpty {
                Button("Nuke \(formatted(selectedBytes))") { confirmingDelete = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
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
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var itemList: some View {
        if visible.isEmpty {
            ContentUnavailableView(activePage == .ignored ? "Nothing ignored" : "Nothing here", systemImage: activePage == .ignored ? "folder" : "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if activePage != .ignored {
                    HStack {
                        Button(action: toggleAll) { Image(systemName: allVisibleSelected ? "checkmark.square.fill" : "square") }.buttonStyle(.borderless)
                        Text(activePage == .nuking ? "Auto-select all" : "Select all").fontWeight(.medium)
                        Spacer()
                        Text("\(visible.count) items").foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
                ForEach(visible) { finding in
                    FindingRow(finding: finding, selected: selected.contains(finding.path), page: activePage, toggle: { toggle(finding) }, reveal: { scanner.reveal(finding) }, ignore: { ignore(finding) }, restore: { restore(finding) })
                }
            }
            .listStyle(.inset)
        }
    }

    private var allVisibleSelected: Bool { !visible.isEmpty && visible.allSatisfy { selected.contains($0.path) } }

    private func runScan() { scanner.scan() }
    private func syncSelection() {
        if activePage == .nuking {
            selected = Set(nukeItems.filter { !excluded.contains($0.path) }.map(\.path))
        } else { selected.removeAll() }
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
        if allVisibleSelected {
            for f in visible { selected.remove(f.path) }
            if activePage == .nuking { var e = excluded; e.formUnion(visible.map(\.path)); excludedStore = e.sorted().joined(separator: "\n") }
        } else {
            for f in visible { selected.insert(f.path) }
            if activePage == .nuking { var e = excluded; e.subtract(visible.map(\.path)); excludedStore = e.sorted().joined(separator: "\n") }
        }
    }
    private func ignore(_ finding: Finding) { var x = ignored; x.insert(finding.path); ignoredStore = x.sorted().joined(separator: "\n"); selected.remove(finding.path) }
    private func restore(_ finding: Finding) { var x = ignored; x.remove(finding.path); ignoredStore = x.sorted().joined(separator: "\n") }
}

struct Stat: View {
    let icon: String, value: String, label: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) { Text(value).fontWeight(.semibold); Text(label).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity)
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
        HStack(alignment: .center, spacing: 12) {
            if page != .ignored {
                Button(action: toggle) { Image(systemName: selected ? "checkmark.square.fill" : "square").font(.system(size: 17)) }.buttonStyle(.borderless)
            }
            Image(systemName: appIcon).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.name).fontWeight(.medium)
                Text(finding.what).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(finding.consequence).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Text(shortPath(finding.path)).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 20)
            Text(formatted(finding.bytes)).fontWeight(.medium).monospacedDigit()
            Menu {
                Button("Show in Finder", action: reveal)
                if page == .ignored { Button("Stop Ignoring", action: restore) }
                else { Button("Ignore on future scans", action: ignore) }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }.menuStyle(.borderlessButton).frame(width: 24)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if page != .ignored { toggle() } }
    }

    private var appIcon: String {
        let n = finding.name.lowercased()
        if n.contains("chrome") { return "globe" }
        if n.contains("homebrew") || n.contains("yarn") { return "shippingbox" }
        if n.contains("adobe") || n.contains("creative") { return "paintbrush" }
        if n.contains("download") { return "arrow.down.circle" }
        return "doc.zipper"
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "hand.raised.fill").font(.system(size: 30)).foregroundStyle(.blue)
            Text("Your files stay yours.").font(.title2).fontWeight(.semibold)
            Text("NUKE scans locally. It doesn't upload your files or require an account. Full Disk Access is optional and only helps NUKE inspect protected locations.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { dismiss() }
                Spacer()
                Button("Open Full Disk Access…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 440)
    }
}

private func friendlyName(_ raw: String) -> String {
    var name = raw.replacingOccurrences(of: "com.", with: "")
    name = name.replacingOccurrences(of: ".ShipIt", with: " updater")
    let parts = name.split(separator: ".")
    if parts.count > 1 { name = parts.last.map(String.init) ?? name }
    return name.replacingOccurrences(of: "-", with: " ").capitalized
}

private func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.replacingOccurrences(of: home, with: "~")
}

private func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
