import SwiftUI
import AppKit

private let acid = Color(red: 0.87, green: 1.0, blue: 0.0)
private let ink = Color(red: 0.035, green: 0.035, blue: 0.035)

@main
struct NukeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 980, height: 720)
    }
}

enum Safety: String, CaseIterable, Sendable {
    case nuke = "NUKE"
    case review = "REVIEW"
    case keep = "KEEP"
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
    @Published var progress = "Ready to scan"
    @Published var lastFreed: Int64 = 0

    private let fm = FileManager.default
    private var home: String { fm.homeDirectoryForCurrentUser.path }

    var nukeBytes: Int64 {
        findings.filter { $0.safety == .nuke }.reduce(0) { $0 + $1.bytes }
    }

    var reviewBytes: Int64 {
        findings.filter { $0.safety == .review }.reduce(0) { $0 + $1.bytes }
    }

    func scan() {
        scanning = true
        progress = "Looking under the couch…"
        lastFreed = 0
        let h = home

        Task.detached(priority: .userInitiated) {
            let rules: [(String, String, String, Safety, Bool)] = [
                ("Google Chrome", "Browser cache · recreated automatically", "\(h)/Library/Caches/Google", .nuke, true),
                ("Chrome on-device model", "Downloaded local model · Chrome can fetch it again", "\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .nuke, true),
                ("Chrome · Default", "Offline website data · recreated as you browse", "\(h)/Library/Application Support/Google/Chrome/Default/Service Worker", .nuke, true),
                ("Chrome · Profile 1", "Offline website data · recreated as you browse", "\(h)/Library/Application Support/Google/Chrome/Profile 1/Service Worker", .nuke, true),
                ("Chrome · Profile 2", "Offline website data · recreated as you browse", "\(h)/Library/Application Support/Google/Chrome/Profile 2/Service Worker", .nuke, true),
                ("Claude local VM", "Local environment · Claude can download it again", "\(h)/Library/Application Support/Claude/vm_bundles", .nuke, true),
                ("Claude cache", "Temporary application cache", "\(h)/Library/Application Support/Claude/Cache", .nuke, true),
                ("Claude code cache", "Compiled app cache · recreated automatically", "\(h)/Library/Application Support/Claude/Code Cache", .nuke, true),
                ("Adobe logs", "Diagnostic logs · not your projects", "\(h)/Library/Logs/Adobe", .nuke, true),
                ("Creative Cloud logs", "Creative Cloud diagnostic logs", "\(h)/Library/Logs/CreativeCloud", .nuke, true),
                ("Codex cache", "Temporary Codex data", "\(h)/Library/Caches/com.openai.codex", .nuke, true),
                ("Homebrew cache", "Downloaded package cache", "\(h)/Library/Caches/Homebrew", .nuke, true),
                ("Yarn cache", "Downloaded package cache", "\(h)/Library/Caches/Yarn", .nuke, true),
                ("Downloads", "Your files · look before you launch", "\(h)/Downloads", .review, false)
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
                        output.append(Finding(name: child, detail: "Large app cache · review if you don't recognize it", path: path, bytes: size, safety: .review, regenerable: false))
                    }
                }
            }

            output.sort { $0.bytes > $1.bytes }
            await MainActor.run {
                self.findings = output
                self.scanning = false
                self.progress = "Scan complete"
            }
        }
    }

    func nukeSafe() {
        let targets = findings.filter { $0.safety == .nuke && $0.regenerable }
        var freed: Int64 = 0
        for target in targets {
            do {
                try fm.removeItem(atPath: target.path)
                freed += target.bytes
            } catch { }
        }
        lastFreed = freed
        scan()
    }

    func reveal(_ finding: Finding) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)])
    }
}

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var privacy = false
    @State private var tab: Safety? = nil

    private var shown: [Finding] {
        guard let tab else { return scanner.findings }
        return scanner.findings.filter { $0.safety == tab }
    }

    private var amountText: String {
        guard !scanner.findings.isEmpty else { return "—" }
        return ByteCountFormatter.string(fromByteCount: scanner.nukeBytes, countStyle: .file)
    }

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        hero
                        if scanner.scanning {
                            ProgressView().tint(acid).scaleEffect(x: 1, y: 1.5).frame(maxWidth: .infinity)
                        }
                        if scanner.lastFreed > 0 { successBanner }
                        filters
                        results
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 24)
                }
                statusBar
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $privacy) { PrivacyView() }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Text("NUKE.").font(.system(size: 24, weight: .black, design: .rounded))
            Spacer()
            Button(action: { privacy = true }) {
                Label("Privacy", systemImage: "lock.fill")
            }
            .buttonStyle(GhostButton())

            Button(action: scanner.scan) {
                Label(scanner.scanning ? "SCANNING" : "SCAN", systemImage: "arrow.clockwise")
            }
            .buttonStyle(GhostButton())
            .disabled(scanner.scanning)
        }
        .padding(.horizontal, 30)
        .frame(height: 72)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(scanner.findings.isEmpty ? "READY WHEN YOU ARE" : "READY TO NUKE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Text(amountText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .tracking(-3)
                Text(scanner.findings.isEmpty ? "Find what's eating your Mac." : "Known junk. Safe to regenerate.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: primaryAction) {
                Text(scanner.findings.isEmpty ? "SCAN MY MAC →" : "NUKE \(ByteCountFormatter.string(fromByteCount: scanner.nukeBytes, countStyle: .file)) →")
            }
            .buttonStyle(NukeButton())
            .disabled(scanner.scanning || (!scanner.findings.isEmpty && scanner.nukeBytes == 0))
        }
        .padding(.top, 22)
    }

    private func primaryAction() {
        if scanner.findings.isEmpty { scanner.scan() }
        else { scanner.nukeSafe() }
    }

    private var successBanner: some View {
        HStack {
            Text("WOOF.").font(.title2).fontWeight(.black)
            Text("\(ByteCountFormatter.string(fromByteCount: scanner.lastFreed, countStyle: .file)) nuked.").foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(acid.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(acid.opacity(0.25)))
    }

    private var filters: some View {
        HStack(spacing: 7) {
            Chip("ALL", tab == nil) { tab = nil }
            ForEach(Safety.allCases, id: \.self) { safety in
                Chip(safety.rawValue, tab == safety) { tab = safety }
            }
            Spacer()
            if scanner.reviewBytes > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: scanner.reviewBytes, countStyle: .file)) needs review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var results: some View {
        if scanner.findings.isEmpty && !scanner.scanning {
            EmptyState(scan: scanner.scan)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(shown) { finding in
                    FindingRow(finding: finding, reveal: { scanner.reveal(finding) })
                }
            }
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(acid).frame(width: 6, height: 6)
            Text("100% LOCAL").font(.system(size: 10, weight: .bold)).tracking(1)
            Text("·  NO UPLOADS  ·  NO ACCOUNT").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(scanner.progress).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 30)
        .frame(height: 48)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }
}

struct EmptyState: View {
    let scan: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).frame(width: 100, height: 100)
                Image(systemName: "sparkles").font(.system(size: 38)).foregroundStyle(acid)
            }
            Text("Nothing scanned yet.").font(.title2).fontWeight(.bold)
            Text("NUKE reads storage metadata locally and tells you what can go.\nNothing leaves this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("START SCAN", action: scan).buttonStyle(GhostButton())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct Chip: View {
    let title: String
    let active: Bool
    let action: () -> Void

    init(_ title: String, _ active: Bool, _ action: @escaping () -> Void) {
        self.title = title
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .bold))
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? Color.white : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(active ? ink : Color.secondary)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.09)))
    }
}

struct FindingRow: View {
    let finding: Finding
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle().fill(finding.safety == .nuke ? acid : Color.white.opacity(0.08)).frame(width: 28, height: 28)
                Image(systemName: finding.safety == .nuke ? "checkmark" : "questionmark")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(finding.safety == .nuke ? ink : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.name).font(.system(size: 14, weight: .semibold))
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                Text(finding.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: finding.bytes, countStyle: .file))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(finding.safety.rawValue)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(finding.safety == .nuke ? acid : Color.secondary)
                .frame(width: 52)
            Button(action: reveal) {
                Image(systemName: "folder").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 78)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 60)
        }
    }
}

struct NukeButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(ink)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background(acid, in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(acid.opacity(0.1)).frame(width: 90, height: 90)
                    Image(systemName: "lock.shield.fill").font(.system(size: 38)).foregroundStyle(acid)
                }
                Text("Your files stay yours.").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("NUKE needs Full Disk Access only for a deeper scan of macOS-protected folders. Nothing leaves your Mac. NUKE doesn't upload, store, or share your files or file data.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 500)
                HStack(spacing: 22) {
                    Label("100% local", systemImage: "checkmark")
                    Label("No uploads", systemImage: "checkmark")
                    Label("No account", systemImage: "checkmark")
                }
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(acid)
                HStack {
                    Button("Not now") { dismiss() }.buttonStyle(GhostButton())
                    Button("GRANT FULL DISK ACCESS →") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                        dismiss()
                    }
                    .buttonStyle(NukeButton())
                }
                Text("You can revoke access anytime in System Settings.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(45)
        }
        .frame(width: 650, height: 440)
        .preferredColorScheme(.dark)
    }
}
