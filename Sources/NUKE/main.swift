import SwiftUI
import AppKit

@main
struct NukeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 760, height: 620)
    }
}

enum Safety: String, CaseIterable, Sendable {
    case nuke = "Safe"
    case review = "Review"
    case keep = "Keep"
}

struct Finding: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let detail: String
    let path: String
    let bytes: Int64
    let safety: Safety
    let regenerable: Bool
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

    var safeBytes: Int64 { findings.filter { $0.safety == .nuke }.reduce(0) { $0 + $1.bytes } }
    var reviewBytes: Int64 { findings.filter { $0.safety == .review }.reduce(0) { $0 + $1.bytes } }

    func scan() {
        scanning = true
        status = "Scanning…"
        lastFreed = 0
        cleanupError = nil
        let h = home

        Task.detached(priority: .userInitiated) {
            let rules: [(String, String, String, Safety, Bool)] = [
                ("Google Chrome cache", "Temporary browser files", "\(h)/Library/Caches/Google", .nuke, true),
                ("Chrome local model", "Downloaded model; Chrome can restore it", "\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .nuke, true),
                ("Chrome Default website data", "Offline website cache", "\(h)/Library/Application Support/Google/Chrome/Default/Service Worker", .nuke, true),
                ("Chrome Profile 1 website data", "Offline website cache", "\(h)/Library/Application Support/Google/Chrome/Profile 1/Service Worker", .nuke, true),
                ("Chrome Profile 2 website data", "Offline website cache", "\(h)/Library/Application Support/Google/Chrome/Profile 2/Service Worker", .nuke, true),
                ("Claude local VM", "Local environment; Claude can restore it", "\(h)/Library/Application Support/Claude/vm_bundles", .nuke, true),
                ("Claude cache", "Temporary app files", "\(h)/Library/Application Support/Claude/Cache", .nuke, true),
                ("Claude code cache", "Recreated automatically", "\(h)/Library/Application Support/Claude/Code Cache", .nuke, true),
                ("Adobe logs", "Diagnostic logs", "\(h)/Library/Logs/Adobe", .nuke, true),
                ("Creative Cloud logs", "Diagnostic logs", "\(h)/Library/Logs/CreativeCloud", .nuke, true),
                ("Codex cache", "Temporary app files", "\(h)/Library/Caches/com.openai.codex", .nuke, true),
                ("Homebrew cache", "Downloaded package files", "\(h)/Library/Caches/Homebrew", .nuke, true),
                ("Yarn cache", "Downloaded package files", "\(h)/Library/Caches/Yarn", .nuke, true),
                ("Downloads", "Your files; review manually", "\(h)/Downloads", .review, false)
            ]

            var output: [Finding] = []
            for rule in rules {
                let size = folderSize(rule.2)
                if size > 0 {
                    output.append(Finding(name: rule.0, detail: rule.1, path: rule.2, bytes: size, safety: rule.3, regenerable: rule.4))
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
                        output.append(Finding(name: child, detail: "Large application cache", path: path, bytes: size, safety: .review, regenerable: false))
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

    func cleanSafe() {
        let targets = findings.filter { $0.safety == .nuke && $0.regenerable }
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
        if !failures.isEmpty { cleanupError = "Couldn’t remove: " + failures.joined(separator: ", ") }
        scan()
    }

    func reveal(_ finding: Finding) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)])
    }
}

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var filter: Safety? = nil
    @State private var showingPrivacy = false
    @State private var confirmingClean = false

    private var visibleFindings: [Finding] {
        guard let filter else { return scanner.findings }
        return scanner.findings.filter { $0.safety == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            controls
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingPrivacy = true
                } label: {
                    Label("Privacy", systemImage: "hand.raised")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: scanner.scan) {
                    Label(scanner.scanning ? "Scanning…" : "Scan", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.scanning)
            }
        }
        .sheet(isPresented: $showingPrivacy) { PrivacyView() }
        .confirmationDialog(
            "Remove safe temporary files?",
            isPresented: $confirmingClean,
            titleVisibility: .visible
        ) {
            Button("Remove \(formatted(scanner.safeBytes))", role: .destructive) { scanner.cleanSafe() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("NUKE will only remove items marked Safe. Review items are left untouched.")
        }
    }

    private var summary: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NUKE")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                if scanner.findings.isEmpty {
                    Text("Free up space on your Mac")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Find temporary files and storage worth reviewing.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(formatted(scanner.safeBytes)) can be removed")
                        .font(.system(size: 28, weight: .semibold))
                    Text("\(formatted(scanner.reviewBytes)) more is worth reviewing.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if scanner.findings.isEmpty {
                Button("Scan Mac", action: scanner.scan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(scanner.scanning)
            } else {
                Button("Clean Up…") { confirmingClean = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(scanner.scanning || scanner.safeBytes == 0)
            }
        }
        .padding(28)
    }

    private var controls: some View {
        HStack {
            Picker("Show", selection: $filter) {
                Text("All").tag(Safety?.none)
                Text("Safe").tag(Safety?.some(.nuke))
                Text("Review").tag(Safety?.some(.review))
                Text("Keep").tag(Safety?.some(.keep))
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            Spacer()
            if scanner.scanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").foregroundStyle(.secondary)
            } else if !scanner.findings.isEmpty {
                Text("\(scanner.findings.count) items")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder private var results: some View {
        if scanner.findings.isEmpty && !scanner.scanning {
            ContentUnavailableView(
                "Ready to scan",
                systemImage: "internaldrive",
                description: Text("Scanning happens locally on this Mac.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scanner.scanning && scanner.findings.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking application data and caches…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visibleFindings) { finding in
                FindingRow(finding: finding) { scanner.reveal(finding) }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
            Text("Scans locally. Nothing is uploaded.")
            Spacer()
            Text(scanner.status)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 38)
    }
}

struct FindingRow: View {
    let finding: Finding
    let reveal: () -> Void

    private var icon: String {
        switch finding.safety {
        case .nuke: return "checkmark.circle.fill"
        case .review: return "exclamationmark.circle"
        case .keep: return "lock.circle"
        }
    }

    private var tint: Color {
        switch finding.safety {
        case .nuke: return .green
        case .review: return .orange
        case .keep: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.name).fontWeight(.medium)
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatted(finding.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(finding.safety.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Button(action: reveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(finding.path)
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Show in Finder", action: reveal)
            Text(finding.path)
        }
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
                .font(.title2)
                .fontWeight(.semibold)
            Text("NUKE scans storage locally. It doesn't upload your files or require an account. Full Disk Access is optional and can help NUKE inspect protected locations.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { dismiss() }
                Spacer()
                Button("Open Full Disk Access…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
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
