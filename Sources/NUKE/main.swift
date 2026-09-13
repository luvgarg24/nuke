import SwiftUI
import AppKit

@main
struct NukeApp: App {
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 1080, height: 720) }
}

enum FindingKind: String, Sendable { case nuke, review }
enum Page: String, CaseIterable, Identifiable {
    case nuking = "Nuking", review = "Review", ignored = "Ignored"
    var id: String { rawValue }
    var icon: String { switch self { case .nuking: return "trash"; case .review: return "eye"; case .ignored: return "folder" } }
}
struct Finding: Identifiable, Hashable, Sendable { let id, name, what, consequence, path: String; let bytes: Int64; let kind: FindingKind }
struct StorageArea: Identifiable, Hashable, Sendable { let id, name, path: String; let bytes: Int64; let icon: String }

nonisolated func itemSize(_ path: String) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0 }
    guard let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey,.isRegularFileKey], options: []) else { return 0 }
    var total: Int64 = 0
    for case let u as URL in e {
        if let v = try? u.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
    }
    return total
}
nonisolated func isProtectedAppleCache(_ name: String) -> Bool {
    let v=name.lowercased(); return v=="apple" || v.hasPrefix("com.apple") || v.hasPrefix("apple.") || v.contains("music") || v.contains("media") || v.contains("photo") || v.contains("itunes")
}
nonisolated func friendlyCacheName(_ raw: String) -> String {
    var v=raw; for p in ["com.google.","com.microsoft.","com.adobe.","com.openai.","com."] { if v.lowercased().hasPrefix(p) { v=String(v.dropFirst(p.count)); break } }
    return v.replacingOccurrences(of: ".ShipIt", with: " updater").replacingOccurrences(of: "-", with: " ").capitalized
}
nonisolated func reviewChildren(in root: String, label: String, threshold: Int64 = 100_000_000) -> [Finding] {
    let fm=FileManager.default
    guard let children=try? fm.contentsOfDirectory(atPath: root) else { return [] }
    return children.compactMap { child in
        guard !child.hasPrefix(".") else { return nil }
        let path=root+"/"+child; let size=itemSize(path)
        guard size >= threshold else { return nil }
        return Finding(id:path,name:child,what:"A large item in \(label).",consequence:"If selected, NUKE moves it to Trash so you can recover it.",path:path,bytes:size,kind:.review)
    }
}

@MainActor final class Scanner: ObservableObject {
    @Published var findings:[Finding]=[]
    @Published var storageAreas:[StorageArea]=[]
    @Published var scanning=false
    @Published var hasScanned=false
    @Published var lastError:String?
    private let fm=FileManager.default
    private var home:String { fm.homeDirectoryForCurrentUser.path }

    func scan() {
        scanning=true; lastError=nil; let h=home
        Task.detached(priority:.userInitiated) {
            let rules:[(String,String,String,String)] = [
                ("Google Chrome cache","Temporary browser files.","Chrome rebuilds these as you browse.","\(h)/Library/Caches/Google"),
                ("Chrome local model","A model Chrome downloaded to run features locally.","Chrome can download it again.","\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"),
                ("Claude local VM","Claude's downloaded local computer environment.","Claude can download a fresh copy when needed.","\(h)/Library/Application Support/Claude/vm_bundles"),
                ("Claude cache","Temporary files Claude leaves behind.","Claude recreates it.","\(h)/Library/Application Support/Claude/Cache"),
                ("Claude code cache","Compiled interface files used to speed up Claude.","Claude recreates it.","\(h)/Library/Application Support/Claude/Code Cache"),
                ("Adobe logs","Diagnostic records from Adobe apps. Not your projects.","Adobe writes new logs when needed.","\(h)/Library/Logs/Adobe"),
                ("Creative Cloud logs","Diagnostic records from Creative Cloud.","Creative Cloud writes new logs later.","\(h)/Library/Logs/CreativeCloud"),
                ("Codex cache","Temporary files Codex keeps locally.","Codex recreates it.","\(h)/Library/Caches/com.openai.codex"),
                ("Homebrew cache","Installers and packages Homebrew already downloaded.","Homebrew downloads them again if required.","\(h)/Library/Caches/Homebrew"),
                ("Yarn cache","Packages Yarn downloaded while installing dependencies.","Yarn downloads them again if required.","\(h)/Library/Caches/Yarn")
            ]
            var out:[Finding]=rules.compactMap { r in
                let s=itemSize(r.3)
                return s>0 ? Finding(id:r.3,name:r.0,what:r.1,consequence:r.2,path:r.3,bytes:s,kind:.nuke) : nil
            }

            for profile in ["Default","Profile 1","Profile 2"] {
                let p="\(h)/Library/Application Support/Google/Chrome/\(profile)/Service Worker"
                let s=itemSize(p)
                if s>0 { out.append(Finding(id:p,name:"Chrome \(profile) website cache",what:"Cached website resources and background workers.",consequence:"Chrome and websites rebuild this as you browse. Offline website content may download again.",path:p,bytes:s,kind:.nuke)) }
            }

            let cacheRoot="\(h)/Library/Caches"
            if let children=try? FileManager.default.contentsOfDirectory(atPath:cacheRoot) {
                let known=Set(out.map(\.path))
                for child in children where !isProtectedAppleCache(child) {
                    let p=cacheRoot+"/"+child
                    guard !known.contains(p) else { continue }
                    let s=itemSize(p); guard s>=250_000_000 else { continue }
                    let app=friendlyCacheName(child)
                    out.append(Finding(id:p,name:"\(app) cache",what:"A large third-party cache.",consequence:"Review it first. NUKE moves it to Trash if selected.",path:p,bytes:s,kind:.review))
                }
            }

            let specs:[(String,String,String)]=[
                ("Downloads","\(h)/Downloads","arrow.down.circle"),
                ("Documents","\(h)/Documents","doc"),
                ("Desktop","\(h)/Desktop","desktopcomputer"),
                ("Pictures","\(h)/Pictures","photo.on.rectangle"),
                ("Movies","\(h)/Movies","film"),
                ("Music","\(h)/Music","music.note")
            ]
            var areas:[StorageArea]=[]
            for spec in specs {
                let s=itemSize(spec.1)
                if s>0 { areas.append(StorageArea(id:spec.1,name:spec.0,path:spec.1,bytes:s,icon:spec.2)) }
                out.append(contentsOf:reviewChildren(in:spec.1,label:spec.0))
            }

            out.sort{$0.bytes>$1.bytes}; areas.sort{$0.bytes>$1.bytes}
            await MainActor.run { self.findings=out; self.storageAreas=areas; self.scanning=false; self.hasScanned=true }
        }
    }

    func delete(_ targets:[Finding]) {
        var errors:[String]=[]
        for t in targets {
            do {
                let u=URL(fileURLWithPath:t.path)
                if t.kind == .review { _=try fm.trashItem(at:u,resultingItemURL:nil) }
                else { try fm.removeItem(at:u) }
            } catch { errors.append("\(t.name): \(error.localizedDescription)") }
        }
        lastError=errors.isEmpty ? nil : errors.joined(separator:"\n"); scan()
    }
    func reveal(_ path:String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) }
}

struct ContentView: View {
    @StateObject private var scanner=Scanner(); @State private var page:Page? = .nuking; @State private var selected=Set<String>(); @State private var showingPrivacy=false; @State private var confirmingDelete=false; @State private var showingError=false
    @AppStorage("ignoredPaths") private var ignoredStore=""; @AppStorage("excludedNukePaths") private var excludedStore=""
    private var ignored:Set<String>{Set(ignoredStore.split(separator:"\n").map(String.init))}; private var excluded:Set<String>{Set(excludedStore.split(separator:"\n").map(String.init))}; private var activePage:Page{page ?? .nuking}
    private var nukeItems:[Finding]{scanner.findings.filter{$0.kind == .nuke && !ignored.contains($0.path)}}; private var reviewItems:[Finding]{scanner.findings.filter{$0.kind == .review && !ignored.contains($0.path)}}; private var ignoredItems:[Finding]{scanner.findings.filter{ignored.contains($0.path)}}
    private var visible:[Finding]{switch activePage{case .nuking:return nukeItems;case .review:return reviewItems;case .ignored:return ignoredItems}}
    private var selectedItems:[Finding]{scanner.findings.filter{selected.contains($0.path)}}; private var selectedBytes:Int64{selectedItems.reduce(0){$0+$1.bytes}}; private var nukeBytes:Int64{nukeItems.reduce(0){$0+$1.bytes}}; private var reviewBytes:Int64{reviewItems.reduce(0){$0+$1.bytes}}; private var ignoredBytes:Int64{ignoredItems.reduce(0){$0+$1.bytes}}; private var allVisibleSelected:Bool{!visible.isEmpty && visible.allSatisfy{selected.contains($0.path)}}
    var body:some View {
        NavigationSplitView { sidebar.navigationSplitViewColumnWidth(min:190,ideal:220,max:250) } detail:{ detail }.frame(minWidth:860,minHeight:580)
            .toolbar{ToolbarItem(placement:.primaryAction){Button(action:runScan){Label(scanner.scanning ? "Scanning…":"Scan",systemImage:"arrow.clockwise")}.disabled(scanner.scanning)}}
            .sheet(isPresented:$showingPrivacy){PrivacyView()}
            .confirmationDialog("Nuke \(formatted(selectedBytes))?",isPresented:$confirmingDelete,titleVisibility:.visible){Button(activePage == .review ? "Move to Trash":"Nuke \(formatted(selectedBytes))",role:.destructive){scanner.delete(selectedItems);selected.removeAll()};Button("Cancel",role:.cancel){}} message:{Text(activePage == .review ? "Review items go to Trash, not permanent deletion.":"Known disposable data will be permanently removed.")}
            .alert("Some items couldn't be removed",isPresented:$showingError){Button("OK") {}} message:{Text(scanner.lastError ?? "Unknown error")}
            .onChange(of:page){_,_ in syncSelection()}.onChange(of:scanner.findings){_,_ in syncSelection()}.onChange(of:scanner.lastError){_,v in if v != nil { showingError=true }}
    }
    private var sidebar:some View { VStack(alignment:.leading,spacing:0){VStack(alignment:.leading,spacing:3){Text("NUKE").font(.system(size:22,weight:.bold));Text("See what's eating your Mac.").font(.caption).foregroundStyle(.secondary)}.padding(16);List(selection:$page){side(.nuking,nukeBytes);side(.review,reviewBytes);side(.ignored,ignoredBytes)}.listStyle(.sidebar);Spacer();Button{showingPrivacy=true}label:{Label("Privacy",systemImage:"hand.raised")}.buttonStyle(.plain).padding(16)} }
    private func side(_ p:Page,_ b:Int64)->some View{Label{HStack{Text(p.rawValue);Spacer();if scanner.hasScanned{Text(formatted(b)).foregroundStyle(.secondary)}}}icon:{Image(systemName:p.icon)}.tag(p)}
    private var detail:some View { ZStack{VStack(spacing:0){if !scanner.hasScanned && !scanner.scanning{welcome}else{header;if activePage == .review && !scanner.storageAreas.isEmpty{storageStrip};if activePage == .nuking && !visible.isEmpty{stats};items}}.background(Color(nsColor:.windowBackgroundColor));if scanner.scanning{overlay}} }
    private var welcome:some View { VStack(spacing:16){Image(systemName:"internaldrive").font(.system(size:42)).foregroundStyle(.secondary);Text("See what's eating your Mac.").font(.system(size:30,weight:.semibold));Text("NUKE shows you what is using your storage, explains why it is there, and lets you remove what you don't need.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth:520);Button("Scan Mac",action:runScan).buttonStyle(.borderedProminent).controlSize(.large);Label("Scans locally. Nothing is uploaded.",systemImage:"lock.fill").font(.caption).foregroundStyle(.tertiary)}.frame(maxWidth:.infinity,maxHeight:.infinity) }
    private var overlay:some View { ZStack{Color(nsColor:.windowBackgroundColor).opacity(0.94).ignoresSafeArea();VStack(spacing:18){ProgressView().controlSize(.large);Text("Scanning your Mac…").font(.title2).fontWeight(.semibold);Text("Finding what's using your storage.").foregroundStyle(.secondary);ProgressView().progressViewStyle(.linear).frame(width:300)}} }
    private var header:some View { HStack(spacing:24){VStack(alignment:.leading,spacing:6){switch activePage{case .nuking:Text("\(formatted(nukeBytes)) worth nuking.").font(.system(size:34,weight:.semibold));Text("Regenerable data. NUKE explains every item before you remove it.").foregroundStyle(.secondary);case .review:Text("\(formatted(reviewBytes)) needs your call.").font(.system(size:34,weight:.semibold));Text("Your large files and uncertain app data. Nothing here is pre-selected.").foregroundStyle(.secondary);case .ignored:Text("\(formatted(ignoredBytes)) ignored.").font(.system(size:34,weight:.semibold));Text("NUKE remembers to leave these alone.").foregroundStyle(.secondary)}};Spacer();if activePage != .ignored && !selected.isEmpty{Button(activePage == .review ? "Trash \(formatted(selectedBytes))":"Nuke \(formatted(selectedBytes))"){confirmingDelete=true}.buttonStyle(.borderedProminent).controlSize(.large)}}.padding(28) }
    private var storageStrip:some View { ScrollView(.horizontal,showsIndicators:false){HStack(spacing:10){ForEach(scanner.storageAreas){a in Button{scanner.reveal(a.path)}label:{HStack(spacing:10){Image(systemName:a.icon).font(.title3);VStack(alignment:.leading,spacing:2){Text(a.name).fontWeight(.medium);Text(formatted(a.bytes)).font(.caption).foregroundStyle(.secondary)}}.padding(.horizontal,13).padding(.vertical,10).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:9))}.buttonStyle(.plain).help("Show \(a.name) in Finder")}}.padding(.horizontal,28).padding(.bottom,14)} }
    private var stats:some View { HStack(spacing:0){Stat(icon:"checkmark.square",value:"\(selected.count)",label:"selected");Divider().frame(height:42);Stat(icon:"internaldrive",value:formatted(selectedBytes),label:"will be freed");Divider().frame(height:42);Stat(icon:"questionmark.circle",value:"Explained",label:"click any item")}.padding(.vertical,14).background(Color(nsColor:.controlBackgroundColor).opacity(0.35)) }
    @ViewBuilder private var items:some View { if visible.isEmpty{ContentUnavailableView(activePage == .ignored ? "Nothing ignored":"Nothing here",systemImage:"checkmark.circle").frame(maxWidth:.infinity,maxHeight:.infinity)}else{List{if activePage != .ignored{HStack{Button(action:toggleAll){Image(systemName:allVisibleSelected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless);Text(activePage == .nuking ? "Auto-select all":"Select all");Spacer();Text("\(visible.count) items").foregroundStyle(.secondary)}.font(.caption).padding(.vertical,4)};ForEach(visible){f in FindingRow(finding:f,selected:selected.contains(f.path),selectable:activePage != .ignored,toggle:{toggle(f)},reveal:{scanner.reveal(f.path)}).contextMenu{Button("Show in Finder"){scanner.reveal(f.path)};Divider();Button(activePage == .ignored ? "Stop Ignoring":"Ignore"){toggleIgnored(f.path)}}}}.listStyle(.inset)} }
    private func runScan(){selected.removeAll();scanner.scan()}
    private func toggle(_ f:Finding){if selected.contains(f.path){selected.remove(f.path)}else{selected.insert(f.path)};if f.kind == .nuke{var s=excluded;if selected.contains(f.path){s.remove(f.path)}else{s.insert(f.path)};excludedStore=s.sorted().joined(separator:"\n")}}
    private func toggleAll(){let wasAll=allVisibleSelected;if wasAll{visible.forEach{selected.remove($0.path)}}else{visible.forEach{selected.insert($0.path)}};if activePage == .nuking{var s=excluded;if wasAll{visible.forEach{s.insert($0.path)}}else{visible.forEach{s.remove($0.path)}};excludedStore=s.sorted().joined(separator:"\n")}}
    private func toggleIgnored(_ p:String){var s=ignored;if s.contains(p){s.remove(p)}else{s.insert(p);selected.remove(p)};ignoredStore=s.sorted().joined(separator:"\n")}
    private func syncSelection(){if activePage == .nuking{selected=Set(nukeItems.filter{!excluded.contains($0.path)}.map(\.path))}else{selected.removeAll()}}
}

struct FindingRow: View {
    let finding: Finding
    let selected: Bool
    let selectable: Bool
    let toggle: () -> Void
    let reveal: () -> Void
    @State private var showingExplanation = false

    var body: some View {
        HStack(spacing:12) {
            if selectable {
                Button(action:toggle){Image(systemName:selected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless).frame(width:26)
            } else { Color.clear.frame(width:26,height:1) }
            VStack(alignment:.leading,spacing:3) {
                Text(finding.name).fontWeight(.medium)
                Text(finding.what).font(.caption).foregroundStyle(.secondary)
                Text(finding.consequence).font(.caption).foregroundStyle(.tertiary)
                Text(shortPath(finding.path)).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }.frame(maxWidth:.infinity,alignment:.leading)
            Text(formatted(finding.bytes)).font(.system(.body,design:.monospaced,weight:.semibold)).monospacedDigit().frame(width:112,alignment:.trailing)
            Button { showingExplanation = true } label: { Image(systemName:"questionmark.circle").foregroundStyle(.secondary).frame(width:30) }.buttonStyle(.borderless).help("Why is this here?")
        }
        .sheet(isPresented:$showingExplanation) { FindingExplanationView(finding:finding,reveal:reveal) }
    }
}

struct FindingExplanationView: View {
    let finding: Finding
    let reveal: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) {
                    Text(finding.name).font(.title2).fontWeight(.semibold)
                    Text(formatted(finding.bytes)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(finding.kind == .nuke ? "NUKE" : "REVIEW").font(.caption).fontWeight(.semibold).padding(.horizontal,9).padding(.vertical,5).background(Color(nsColor:.controlBackgroundColor)).clipShape(Capsule())
            }
            Divider()
            VStack(alignment:.leading,spacing:7) { Text("What is this?").fontWeight(.semibold); Text(finding.what).foregroundStyle(.secondary) }
            VStack(alignment:.leading,spacing:7) { Text(finding.kind == .nuke ? "What happens if I nuke it?" : "What happens if I remove it?").fontWeight(.semibold); Text(finding.consequence).foregroundStyle(.secondary) }
            VStack(alignment:.leading,spacing:7) { Text("Where is it?").fontWeight(.semibold); Text(shortPath(finding.path)).font(.callout.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) }
            Spacer()
            HStack { Button("Show in Finder",action:reveal); Spacer(); Button("Done"){dismiss()}.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width:520,height:360)
    }
}

struct Stat:View { let icon,value,label:String;var body:some View{HStack(spacing:10){Image(systemName:icon).foregroundStyle(.secondary);VStack(alignment:.leading){Text(value).fontWeight(.semibold);Text(label).font(.caption).foregroundStyle(.secondary)}}.frame(maxWidth:.infinity)} }
struct PrivacyView:View { @Environment(\.dismiss) private var dismiss;var body:some View{VStack(alignment:.leading,spacing:18){Image(systemName:"hand.raised.fill").font(.system(size:30));Text("Your files stay yours.").font(.title2).fontWeight(.semibold);Text("NUKE scans locally. It doesn't upload your files or require an account.").foregroundStyle(.secondary);Button("Done"){dismiss()}.frame(maxWidth:.infinity,alignment:.trailing)}.padding(28).frame(width:440)} }
private func shortPath(_ p:String)->String{p.replacingOccurrences(of:FileManager.default.homeDirectoryForCurrentUser.path,with:"~")}
private func formatted(_ b:Int64)->String{ByteCountFormatter.string(fromByteCount:b,countStyle:.file)}
