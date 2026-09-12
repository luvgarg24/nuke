import SwiftUI
import AppKit

@main
struct NukeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 920, height: 680)
    }
}

enum Safety: String, CaseIterable { case nuke = "NUKE", review = "REVIEW", keep = "KEEP" }

struct Finding: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let detail: String
    let path: String
    let bytes: Int64
    let safety: Safety
    let regenerable: Bool
}

@MainActor
final class Scanner: ObservableObject {
    @Published var findings: [Finding] = []
    @Published var scanning = false
    @Published var progress = "Ready"
    @Published var lastFreed: Int64 = 0

    var nukeBytes: Int64 { findings.filter{$0.safety == .nuke}.reduce(0){$0 + $1.bytes} }
    var reviewBytes: Int64 { findings.filter{$0.safety == .review}.reduce(0){$0 + $1.bytes} }

    private let fm = FileManager.default
    private var home: String { fm.homeDirectoryForCurrentUser.path }

    func scan() {
        scanning = true; progress = "Looking for junk…"; lastFreed = 0
        Task.detached(priority: .userInitiated) { [home] in
            let rules: [(String,String,String,Safety,Bool)] = [
                ("Google cache", "Browser cache. Recreated automatically.", "\(home)/Library/Caches/Google", .nuke, true),
                ("Chrome on-device model", "Downloaded optimization/AI model. Chrome may download it again.", "\(home)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .nuke, true),
                ("Chrome Default service workers", "Offline website cache. Sites may re-download data.", "\(home)/Library/Application Support/Google/Chrome/Default/Service Worker", .nuke, true),
                ("Chrome Profile 1 service workers", "Offline website cache. Sites may re-download data.", "\(home)/Library/Application Support/Google/Chrome/Profile 1/Service Worker", .nuke, true),
                ("Chrome Profile 2 service workers", "Offline website cache. Sites may re-download data.", "\(home)/Library/Application Support/Google/Chrome/Profile 2/Service Worker", .nuke, true),
                ("Claude local VM", "Local VM bundle. Claude can recreate/download it.", "\(home)/Library/Application Support/Claude/vm_bundles", .nuke, true),
                ("Claude cache", "Temporary Claude application cache.", "\(home)/Library/Application Support/Claude/Cache", .nuke, true),
                ("Claude code cache", "Compiled web cache. Recreated automatically.", "\(home)/Library/Application Support/Claude/Code Cache", .nuke, true),
                ("Adobe logs", "Diagnostic logs, not your projects.", "\(home)/Library/Logs/Adobe", .nuke, true),
                ("Creative Cloud logs", "Creative Cloud diagnostic logs.", "\(home)/Library/Logs/CreativeCloud", .nuke, true),
                ("Codex cache", "Temporary Codex cache.", "\(home)/Library/Caches/com.openai.codex", .nuke, true),
                ("Homebrew cache", "Downloaded formula/package cache.", "\(home)/Library/Caches/Homebrew", .nuke, true),
                ("Yarn cache", "Package download cache.", "\(home)/Library/Caches/Yarn", .nuke, true),
                ("Downloads", "Your files. Review large/duplicate archives manually.", "\(home)/Downloads", .review, false)
            ]
            var result: [Finding] = []
            for r in rules {
                let size = Self.folderSize(r.2)
                if size > 0 { result.append(Finding(name:r.0, detail:r.1, path:r.2, bytes:size, safety:r.3, regenerable:r.4)) }
            }
            // Generic large cache buckets not already covered.
            let cacheRoot = "\(home)/Library/Caches"
            if let children = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot) {
                let known = Set(result.map{$0.path})
                for child in children {
                    let p = cacheRoot + "/" + child
                    if known.contains(p) { continue }
                    let s = Self.folderSize(p)
                    if s >= 250_000_000 { result.append(Finding(name: child, detail:"Large application cache. Review if you don't recognize the app.", path:p, bytes:s, safety:.review, regenerable:false)) }
                }
            }
            result.sort { $0.bytes > $1.bytes }
            await MainActor.run { self.findings = result; self.scanning = false; self.progress = "Scan complete" }
        }
    }

    func nukeSafe() {
        let targets = findings.filter { $0.safety == .nuke && $0.regenerable }
        var freed: Int64 = 0
        for f in targets {
            do { try fm.removeItem(atPath: f.path); freed += f.bytes } catch { }
        }
        lastFreed = freed
        scan()
    }

    func reveal(_ f: Finding) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:f.path)]) }

    static func folderSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath:path, isDirectory:&isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath:path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let en = fm.enumerator(at: URL(fileURLWithPath:path), includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey], options:[.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            if let v = try? u.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }
}

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var showPrivacy = false
    @State private var tab: Safety? = nil

    var shown: [Finding] { tab == nil ? scanner.findings : scanner.findings.filter{$0.safety == tab} }
    var body: some View {
        ZStack {
            Color(nsColor:.windowBackgroundColor).ignoresSafeArea()
            VStack(spacing:0) {
                HStack {
                    Text("NUKE").font(.system(size:24, weight:.black, design:.rounded))
                    Spacer()
                    Button { showPrivacy = true } label: { Label("Privacy", systemImage:"lock.fill") }.buttonStyle(.plain)
                    Button(action:scanner.scan) { Label(scanner.scanning ? "Scanning…" : "Scan", systemImage:"arrow.clockwise") }.disabled(scanner.scanning)
                }.padding(24)

                ScrollView {
                    VStack(alignment:.leading, spacing:22) {
                        HStack(alignment:.bottom) {
                            VStack(alignment:.leading, spacing:5) {
                                Text(ByteCountFormatter.string(fromByteCount: scanner.nukeBytes, countStyle:.file)).font(.system(size:52, weight:.bold, design:.rounded))
                                Text("safe to nuke").font(.title3).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("NUKE \(ByteCountFormatter.string(fromByteCount: scanner.nukeBytes, countStyle:.file))") { scanner.nukeSafe() }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(scanner.nukeBytes == 0 || scanner.scanning)
                        }
                        if scanner.lastFreed > 0 { Text("WOOF. \(ByteCountFormatter.string(fromByteCount: scanner.lastFreed, countStyle:.file)) nuked.").font(.headline) }
                        HStack(spacing:8) {
                            FilterChip(title:"ALL", active:tab == nil){tab=nil}
                            ForEach(Safety.allCases, id:\.self) { s in FilterChip(title:s.rawValue, active:tab == s){tab=s} }
                        }
                        if scanner.findings.isEmpty && !scanner.scanning {
                            VStack(spacing:14) {
                                Image(systemName:"burst.fill").font(.system(size:48))
                                Text("Find what's eating your Mac.").font(.title2.bold())
                                Text("No uploads. No account. Nothing leaves your Mac.").foregroundStyle(.secondary)
                                Button("SCAN MY MAC", action:scanner.scan).buttonStyle(.borderedProminent).controlSize(.large)
                            }.frame(maxWidth:.infinity).padding(.vertical,70)
                        } else {
                            LazyVStack(spacing:10) { ForEach(shown) { f in FindingRow(f:f, reveal:{scanner.reveal(f)}) } }
                        }
                    }.padding(28)
                }
                HStack { Image(systemName:"lock.fill"); Text("100% local · no uploads · no account required"); Spacer(); Text(scanner.progress) }
                    .font(.caption).foregroundStyle(.secondary).padding(16).background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented:$showPrivacy) { PrivacyView() }
    }
}

struct FilterChip: View {
    let title:String; let active:Bool; let action:()->Void
    var body: some View { Button(title, action:action).buttonStyle(.bordered).tint(active ? .primary : .secondary) }
}

struct FindingRow: View {
    let f:Finding; let reveal:()->Void
    var body: some View {
        HStack(spacing:14) {
            Image(systemName: f.safety == .nuke ? "checkmark.circle.fill" : f.safety == .review ? "questionmark.circle.fill" : "lock.circle.fill").font(.title2)
            VStack(alignment:.leading, spacing:4) { Text(f.name).font(.headline); Text(f.detail).foregroundStyle(.secondary); Text(f.path).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
            Spacer(); Text(ByteCountFormatter.string(fromByteCount:f.bytes,countStyle:.file)).font(.headline.monospacedDigit()); Text(f.safety.rawValue).font(.caption.bold()).padding(.horizontal,8).padding(.vertical,4).background(.quaternary,in:Capsule()); Button(action:reveal){Image(systemName:"folder")}.buttonStyle(.plain)
        }.padding(16).background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing:18) {
            Image(systemName:"lock.shield.fill").font(.system(size:48))
            Text("Your files stay yours.").font(.largeTitle.bold())
            Text("NUKE needs Full Disk Access for a deeper scan of storage inside macOS-protected folders. Nothing leaves your Mac. NUKE doesn't upload, store, or share your files or file data. Everything is scanned locally on your device.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth:480)
            HStack { Label("100% local",systemImage:"checkmark"); Label("No uploads",systemImage:"checkmark"); Label("No account",systemImage:"checkmark") }.font(.callout.bold())
            HStack { Button("Not now"){dismiss()}; Button("Grant Full Disk Access") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!); dismiss() }.buttonStyle(.borderedProminent) }
            Text("You can revoke access anytime in System Settings.").font(.caption).foregroundStyle(.tertiary)
        }.padding(40).frame(width:620,height:390)
    }
}
