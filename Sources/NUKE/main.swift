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
    case nuking = "Nuking", review = "Review", ignored = "Ignored"
    var id: String { rawValue }
    var icon: String { switch self { case .nuking: "trash"; case .review: "eye"; case .ignored: "folder" } }
}

struct Finding: Identifiable, Hashable, Sendable {
    let id: String, name: String, what: String, consequence: String, path: String
    let bytes: Int64
    let kind: FindingKind
}

nonisolated func folderSize(_ path: String) -> Int64 {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
    if !isDirectory.boolValue { return (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0 }
    guard let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in e {
        if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
    }
    return total
}

@MainActor final class Scanner: ObservableObject {
    @Published var findings: [Finding] = []
    @Published var scanning = false
    @Published var status = "Not scanned"
    @Published var hasScanned = false
    @Published var deepScanned = false
    private let fm = FileManager.default
    private var home: String { fm.homeDirectoryForCurrentUser.path }

    func scan(deep: Bool = false) {
        scanning = true
        status = deep ? "Digging deeper…" : "Scanning…"
        let h = home
        Task.detached(priority: .userInitiated) {
            let rules: [(String,String,String,String,FindingKind)] = [
                ("Google Chrome cache","Temporary browser files.","Chrome rebuilds these as you browse.","\(h)/Library/Caches/Google",.nuke),
                ("Chrome local model","A model Chrome downloaded to run features on your Mac.","Chrome may download it again if it needs it.","\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel",.nuke),
                ("Chrome Default website data","Offline copies and background data saved by websites.","Sites rebuild it; offline site data may be lost.","\(h)/Library/Application Support/Google/Chrome/Default/Service Worker",.nuke),
                ("Chrome Profile 1 website data","Offline copies and background data saved by websites in Profile 1.","Sites rebuild it; offline site data may be lost.","\(h)/Library/Application Support/Google/Chrome/Profile 1/Service Worker",.nuke),
                ("Chrome Profile 2 website data","Offline copies and background data saved by websites in Profile 2.","Sites rebuild it; offline site data may be lost.","\(h)/Library/Application Support/Google/Chrome/Profile 2/Service Worker",.nuke),
                ("Claude local VM","Claude's downloaded local computer environment.","Claude can download a fresh copy when needed.","\(h)/Library/Application Support/Claude/vm_bundles",.nuke),
                ("Claude cache","Temporary files Claude leaves behind.","Claude recreates it.","\(h)/Library/Application Support/Claude/Cache",.nuke),
                ("Claude code cache","Compiled interface files used to speed up Claude.","Claude recreates it.","\(h)/Library/Application Support/Claude/Code Cache",.nuke),
                ("Adobe logs","Diagnostic records from Adobe apps. Not your projects.","Adobe writes new logs when needed.","\(h)/Library/Logs/Adobe",.nuke),
                ("Creative Cloud logs","Diagnostic records from Creative Cloud.","Creative Cloud writes new logs later.","\(h)/Library/Logs/CreativeCloud",.nuke),
                ("Codex cache","Temporary files Codex keeps locally.","Codex recreates it.","\(h)/Library/Caches/com.openai.codex",.nuke),
                ("Homebrew cache","Installers and packages Homebrew already downloaded.","Homebrew downloads them again if required.","\(h)/Library/Caches/Homebrew",.nuke),
                ("Yarn cache","Packages Yarn downloaded while installing dependencies.","Yarn downloads them again if required.","\(h)/Library/Caches/Yarn",.nuke),
                ("Downloads","Your Downloads folder. These are your actual files.","Your call. Open it first if you are unsure.","\(h)/Downloads",.review)
            ]
            var output: [Finding] = []
            for r in rules { let s = folderSize(r.3); if s > 0 { output.append(Finding(id:r.3,name:r.0,what:r.1,consequence:r.2,path:r.3,bytes:s,kind:r.4)) } }
            let cacheRoot = "\(h)/Library/Caches"
            if let children = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot) {
                let known = Set(output.map(\.path))
                for child in children {
                    let path = cacheRoot + "/" + child
                    if known.contains(path) { continue }
                    let s = folderSize(path)
                    if s >= 250_000_000 { output.append(Finding(id:path,name:friendlyName(child),what:"A large cache created by \(friendlyName(child)).",consequence:"Check it, then nuke it if you don't need the cached data.",path:path,bytes:s,kind:.review)) }
                }
            }
            if deep {
                let protected: [(String,String,String)] = [
                    ("Mail data","Mail's local database and downloaded message data.","\(h)/Library/Mail"),
                    ("Messages data","Local Messages attachments and databases.","\(h)/Library/Messages"),
                    ("Safari data","Safari's local browser data.","\(h)/Library/Safari")
                ]
                for p in protected {
                    let s = folderSize(p.2)
                    if s > 0 { output.append(Finding(id:p.2,name:p.0,what:p.1,consequence:"Personal data. NUKE will never pre-select this.",path:p.2,bytes:s,kind:.review)) }
                }
            }
            output.sort { $0.bytes > $1.bytes }
            await MainActor.run { self.findings=output; self.scanning=false; self.hasScanned=true; self.deepScanned=deep; self.status=deep ? "Deep scan complete" : "Scan complete" }
        }
    }

    func delete(_ targets: [Finding]) {
        for t in targets { try? fm.removeItem(atPath: t.path) }
        scan(deep: deepScanned)
    }
    func reveal(_ f: Finding) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:f.path)]) }
}

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var page: Page? = .nuking
    @State private var selected = Set<String>()
    @State private var showingPrivacy = false
    @State private var showingDeepAccess = false
    @State private var confirmingDelete = false
    @AppStorage("ignoredPaths") private var ignoredStore = ""
    @AppStorage("excludedNukePaths") private var excludedStore = ""

    private var ignored:Set<String>{Set(ignoredStore.split(separator:"\n").map(String.init))}
    private var excluded:Set<String>{Set(excludedStore.split(separator:"\n").map(String.init))}
    private var activePage:Page{page ?? .nuking}
    private var nukeItems:[Finding]{scanner.findings.filter{$0.kind == .nuke && !ignored.contains($0.path)}}
    private var reviewItems:[Finding]{scanner.findings.filter{$0.kind == .review && !ignored.contains($0.path)}}
    private var ignoredItems:[Finding]{scanner.findings.filter{ignored.contains($0.path)}}
    private var visible:[Finding]{switch activePage{case .nuking:nukeItems;case .review:reviewItems;case .ignored:ignoredItems}}
    private var selectedItems:[Finding]{scanner.findings.filter{selected.contains($0.path)}}
    private var selectedBytes:Int64{selectedItems.reduce(0){$0+$1.bytes}}
    private var nukeBytes:Int64{nukeItems.reduce(0){$0+$1.bytes}}
    private var reviewBytes:Int64{reviewItems.reduce(0){$0+$1.bytes}}
    private var ignoredBytes:Int64{ignoredItems.reduce(0){$0+$1.bytes}}

    var body: some View {
        NavigationSplitView { sidebar.navigationSplitViewColumnWidth(min:190,ideal:220,max:250) } detail: { detail }
            .frame(minWidth:820,minHeight:560)
            .toolbar { ToolbarItem(placement:.primaryAction) { Button(action:runScan){Label(scanner.scanning ? "Scanning…":"Scan",systemImage:"arrow.clockwise")}.disabled(scanner.scanning) } }
            .sheet(isPresented:$showingPrivacy){PrivacyView()}
            .sheet(isPresented:$showingDeepAccess){DeepAccessView { scanner.scan(deep:true) }}
            .confirmationDialog("Nuke \(formatted(selectedBytes))?",isPresented:$confirmingDelete,titleVisibility:.visible){Button("Nuke \(formatted(selectedBytes))",role:.destructive){scanner.delete(selectedItems);selected.removeAll()};Button("Cancel",role:.cancel){}}
            .onChange(of:page){_,_ in syncSelection()}.onChange(of:scanner.findings){_,_ in syncSelection()}
    }

    private var sidebar: some View {
        VStack(alignment:.leading,spacing:0){
            VStack(alignment:.leading,spacing:3){Text("NUKE").font(.system(size:22,weight:.bold));Text("Free up space on your Mac.").font(.caption).foregroundStyle(.secondary)}.padding(16)
            List(selection:$page){
                Label{HStack{Text("Nuking");Spacer();if scanner.hasScanned{Text(formatted(nukeBytes)).foregroundStyle(.secondary)}}}icon:{Image(systemName:Page.nuking.icon)}.tag(Page.nuking)
                Label{HStack{Text("Review");Spacer();if scanner.hasScanned{Text(formatted(reviewBytes)).foregroundStyle(.secondary)}}}icon:{Image(systemName:Page.review.icon)}.tag(Page.review)
                Label{HStack{Text("Ignored");Spacer();if scanner.hasScanned{Text(formatted(ignoredBytes)).foregroundStyle(.secondary)}}}icon:{Image(systemName:Page.ignored.icon)}.tag(Page.ignored)
            }.listStyle(.sidebar)
            Spacer()
            Button{showingPrivacy=true}label:{Label("Privacy",systemImage:"hand.raised")}.buttonStyle(.plain).padding(16)
        }
    }

    private var detail: some View {
        VStack(spacing:0){
            if !scanner.hasScanned && !scanner.scanning { welcome }
            else if scanner.scanning && scanner.findings.isEmpty { VStack(spacing:12){ProgressView();Text(scanner.status).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { pageHeader; if activePage == .nuking && !visible.isEmpty { stats }; itemList }
        }.background(Color(nsColor:.windowBackgroundColor))
    }

    private var welcome: some View { VStack(spacing:16){Image(systemName:"internaldrive").font(.system(size:42)).foregroundStyle(.secondary);Text("See what's eating your Mac.").font(.system(size:30,weight:.semibold));Text("Start with a normal scan. No extra access needed.").foregroundStyle(.secondary);Button("Scan Mac",action:runScan).buttonStyle(.borderedProminent).controlSize(.large);Label("Scans locally. Nothing is uploaded.",systemImage:"lock.fill").font(.caption).foregroundStyle(.tertiary)}.frame(maxWidth:.infinity,maxHeight:.infinity) }

    private var pageHeader: some View {
        HStack(spacing:24){
            VStack(alignment:.leading,spacing:6){
                if activePage == .nuking { Text("\(formatted(nukeBytes)) worth nuking.").font(.system(size:34,weight:.semibold));Text("Temporary data apps can recreate. Pre-selected for you.").foregroundStyle(.secondary) }
                else if activePage == .review { Text("\(formatted(reviewBytes)) needs your call.").font(.system(size:34,weight:.semibold));Text("NUKE won't touch this unless you choose it.").foregroundStyle(.secondary) }
                else { Text("\(formatted(ignoredBytes)) ignored.").font(.system(size:34,weight:.semibold));Text("NUKE leaves these alone.").foregroundStyle(.secondary) }
            }
            Spacer()
            if scanner.hasScanned && !scanner.deepScanned { Button("Dig Deeper…"){showingDeepAccess=true}.controlSize(.large) }
            if activePage != .ignored && !selected.isEmpty { Button("Nuke \(formatted(selectedBytes))"){confirmingDelete=true}.buttonStyle(.borderedProminent).controlSize(.large) }
        }.padding(28)
    }

    private var stats: some View { HStack(spacing:0){Stat(icon:"checkmark.square",value:"\(selected.count)",label:"selected");Divider().frame(height:42);Stat(icon:"internaldrive",value:formatted(selectedBytes),label:"will be freed");Divider().frame(height:42);Stat(icon:"arrow.clockwise",value:"Recreatable",label:"apps can rebuild it")}.padding(.vertical,14).background(Color(nsColor:.controlBackgroundColor).opacity(0.35)) }

    @ViewBuilder private var itemList: some View {
        if visible.isEmpty { ContentUnavailableView(activePage == .ignored ? "Nothing ignored":"Nothing here",systemImage:"checkmark.circle").frame(maxWidth:.infinity,maxHeight:.infinity) }
        else { List { if activePage != .ignored { HStack{Button(action:toggleAll){Image(systemName:allVisibleSelected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless);Text(activePage == .nuking ? "Auto-select all":"Select all");Spacer();Text("\(visible.count) items").foregroundStyle(.secondary)} }; ForEach(visible){f in FindingRow(finding:f,selected:selected.contains(f.path),page:activePage,toggle:{toggle(f)},reveal:{scanner.reveal(f)},ignore:{ignore(f)},restore:{restore(f)})} }.listStyle(.inset) }
    }

    private var allVisibleSelected:Bool{!visible.isEmpty && visible.allSatisfy{selected.contains($0.path)}}
    private func runScan(){selected.removeAll();scanner.scan()}
    private func syncSelection(){if activePage == .nuking{selected=Set(nukeItems.filter{!excluded.contains($0.path)}.map(\.path))}else{selected.removeAll()}}
    private func toggle(_ f:Finding){if selected.contains(f.path){selected.remove(f.path);if f.kind == .nuke{var e=excluded;e.insert(f.path);excludedStore=e.sorted().joined(separator:"\n")}}else{selected.insert(f.path);if f.kind == .nuke{var e=excluded;e.remove(f.path);excludedStore=e.sorted().joined(separator:"\n")}}}
    private func toggleAll(){if allVisibleSelected{for f in visible{selected.remove(f.path)}}else{for f in visible{selected.insert(f.path)}}}
    private func ignore(_ f:Finding){var x=ignored;x.insert(f.path);ignoredStore=x.sorted().joined(separator:"\n");selected.remove(f.path)}
    private func restore(_ f:Finding){var x=ignored;x.remove(f.path);ignoredStore=x.sorted().joined(separator:"\n")}
}

struct DeepAccessView: View {
    @Environment(\.dismiss) private var dismiss
    let deepScan: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:18){
            Image(systemName:"internaldrive.fill.badge.magnifyingglass").font(.system(size:34)).foregroundStyle(.blue)
            Text("Dig deeper?").font(.title2).fontWeight(.semibold)
            Text("The first scan only checks what macOS lets NUKE see normally. Full Disk Access lets NUKE measure protected locations like Mail, Messages and Safari data.").foregroundStyle(.secondary)
            Text("NUKE still scans locally. Nothing is uploaded.").font(.callout).fontWeight(.medium)
            Divider()
            Text("macOS doesn't let apps switch this permission on themselves. Add NUKE in Full Disk Access, turn it on, then come back and run the deep scan.").font(.caption).foregroundStyle(.secondary)
            HStack{
                Button("Not Now"){dismiss()}
                Spacer()
                Button("Show NUKE.app"){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
                Button("Open Full Disk Access"){if let u=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"){NSWorkspace.shared.open(u)}}.buttonStyle(.borderedProminent)
            }
            Button("I've enabled access — Deep Scan"){dismiss();deepScan()}.frame(maxWidth:.infinity,alignment:.trailing)
        }.padding(28).frame(width:560)
    }
}

struct Stat:View{let icon:String,value:String,label:String;var body:some View{HStack(spacing:10){Image(systemName:icon).foregroundStyle(.secondary);VStack(alignment:.leading){Text(value).fontWeight(.semibold);Text(label).font(.caption).foregroundStyle(.secondary)}}.frame(maxWidth:.infinity)}}
struct FindingRow:View{let finding:Finding;let selected:Bool;let page:Page;let toggle:()->Void;let reveal:()->Void;let ignore:()->Void;let restore:()->Void;var body:some View{HStack(spacing:12){if page != .ignored{Button(action:toggle){Image(systemName:selected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless)};VStack(alignment:.leading,spacing:3){Text(finding.name).fontWeight(.medium);Text(finding.what).font(.caption).foregroundStyle(.secondary);Text(finding.consequence).font(.caption).foregroundStyle(.tertiary);Text(shortPath(finding.path)).font(.caption2.monospaced()).foregroundStyle(.tertiary)};Spacer();Text(formatted(finding.bytes)).fontWeight(.medium);Menu{Button("Show in Finder",action:reveal);if page == .ignored{Button("Stop Ignoring",action:restore)}else{Button("Ignore on future scans",action:ignore)}}label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton)}.padding(.vertical,7).contentShape(Rectangle()).onTapGesture{if page != .ignored{toggle()}}}}
struct PrivacyView:View{@Environment(\.dismiss)private var dismiss;var body:some View{VStack(alignment:.leading,spacing:18){Image(systemName:"hand.raised.fill").font(.system(size:30)).foregroundStyle(.blue);Text("Your files stay yours.").font(.title2).fontWeight(.semibold);Text("NUKE scans locally. It doesn't upload your files or require an account.").foregroundStyle(.secondary);Button("Done"){dismiss()}.frame(maxWidth:.infinity,alignment:.trailing)}.padding(28).frame(width:440)}}
private func friendlyName(_ raw:String)->String{var n=raw.replacingOccurrences(of:"com.",with:"");n=n.replacingOccurrences(of:".ShipIt",with:" updater");let p=n.split(separator:".");if p.count>1{n=p.last.map(String.init) ?? n};return n.replacingOccurrences(of:"-",with:" ").capitalized}
private func shortPath(_ path:String)->String{path.replacingOccurrences(of:FileManager.default.homeDirectoryForCurrentUser.path,with:"~")}
private func formatted(_ bytes:Int64)->String{ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)}
