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
struct FindingGroup: Identifiable, Hashable {
    let id:String; let name:String; let summary:String; let findings:[Finding]
    var bytes:Int64 { findings.reduce(0){$0+$1.bytes} }
}

nonisolated func itemSize(_ path: String) -> Int64 {
    let fm = FileManager.default; var isDir: ObjCBool = false
    guard fm.fileExists(atPath:path,isDirectory:&isDir) else { return 0 }
    if !isDir.boolValue { return (try? fm.attributesOfItem(atPath:path)[.size] as? NSNumber)?.int64Value ?? 0 }
    guard let e=fm.enumerator(at:URL(fileURLWithPath:path),includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey],options:[]) else { return 0 }
    var total:Int64=0
    for case let u as URL in e { if let v=try? u.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]),v.isRegularFile==true { total += Int64(v.fileSize ?? 0) } }
    return total
}
nonisolated func isProtectedAppleCache(_ name:String)->Bool { let v=name.lowercased(); return v=="apple" || v.hasPrefix("com.apple") || v.hasPrefix("apple.") || v.contains("music") || v.contains("media") || v.contains("photo") || v.contains("itunes") }
nonisolated func friendlyCacheName(_ raw:String)->String { var v=raw; for p in ["com.google.","com.microsoft.","com.adobe.","com.openai.","com."] { if v.lowercased().hasPrefix(p){v=String(v.dropFirst(p.count));break} }; return v.replacingOccurrences(of:".ShipIt",with:" updater").replacingOccurrences(of:"-",with:" ").capitalized }
nonisolated func reviewChildren(in root:String,label:String,threshold:Int64=100_000_000)->[Finding] { let fm=FileManager.default; guard let children=try? fm.contentsOfDirectory(atPath:root) else{return[]}; return children.compactMap{child in guard !child.hasPrefix(".") else{return nil};let path=root+"/"+child;let size=itemSize(path);guard size>=threshold else{return nil};return Finding(id:path,name:child,what:"A large item in \(label).",consequence:"If selected, NUKE moves it to Trash so you can recover it.",path:path,bytes:size,kind:.review)} }

@MainActor final class Scanner:ObservableObject {
    @Published var findings:[Finding]=[];@Published var storageAreas:[StorageArea]=[];@Published var scanning=false;@Published var hasScanned=false;@Published var lastError:String?
    private let fm=FileManager.default;private var home:String{fm.homeDirectoryForCurrentUser.path}
    func scan(){
        scanning=true;lastError=nil;let h=home
        Task.detached(priority:.userInitiated){
            let rules:[(String,String,String,String)]=[
                ("Google Chrome cache","Temporary browser files.","Chrome rebuilds these as you browse.","\(h)/Library/Caches/Google"),
                ("Chrome local model","A model Chrome downloaded to run features locally.","Chrome can download it again.","\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"),
                ("Claude local VM","Claude's downloaded local computer environment.","Claude can download a fresh copy when needed.","\(h)/Library/Application Support/Claude/vm_bundles"),
                ("Claude cache","Temporary files Claude leaves behind.","Claude recreates it.","\(h)/Library/Application Support/Claude/Cache"),
                ("Claude code cache","Compiled interface files used to speed up Claude.","Claude recreates it.","\(h)/Library/Application Support/Claude/Code Cache"),
                ("Adobe logs","Diagnostic records from Adobe apps. Not your projects.","Adobe writes new logs when needed.","\(h)/Library/Logs/Adobe"),
                ("Creative Cloud logs","Diagnostic records from Creative Cloud.","Creative Cloud writes new logs later.","\(h)/Library/Logs/CreativeCloud"),
                ("Codex cache","Temporary files Codex keeps locally.","Codex recreates it.","\(h)/Library/Caches/com.openai.codex"),
                ("Homebrew cache","Installers and packages Homebrew already downloaded.","Homebrew downloads them again if required.","\(h)/Library/Caches/Homebrew"),
                ("Yarn cache","Packages Yarn downloaded while installing dependencies.","Yarn downloads them again if required.","\(h)/Library/Caches/Yarn")]
            var out:[Finding]=rules.compactMap{r in let s=itemSize(r.3);return s>0 ? Finding(id:r.3,name:r.0,what:r.1,consequence:r.2,path:r.3,bytes:s,kind:.nuke):nil}
            for profile in ["Default","Profile 1","Profile 2"]{let p="\(h)/Library/Application Support/Google/Chrome/\(profile)/Service Worker";let s=itemSize(p);if s>0{out.append(Finding(id:p,name:"Chrome \(profile) website cache",what:"Cached website resources and background workers.",consequence:"Chrome and websites rebuild this as you browse. Offline website content may download again.",path:p,bytes:s,kind:.nuke))}}
            let cacheRoot="\(h)/Library/Caches"
            if let children=try? FileManager.default.contentsOfDirectory(atPath:cacheRoot){let known=Set(out.map(\.path));for child in children where !isProtectedAppleCache(child){let p=cacheRoot+"/"+child;guard !known.contains(p) else{continue};let s=itemSize(p);guard s>=250_000_000 else{continue};let app=friendlyCacheName(child);out.append(Finding(id:p,name:"\(app) cache",what:"A large third-party cache.",consequence:"Review it first. NUKE moves it to Trash if selected.",path:p,bytes:s,kind:.review))}}
            let specs:[(String,String,String)]=[("Downloads","\(h)/Downloads","arrow.down.circle"),("Documents","\(h)/Documents","doc"),("Desktop","\(h)/Desktop","desktopcomputer"),("Pictures","\(h)/Pictures","photo.on.rectangle"),("Movies","\(h)/Movies","film"),("Music","\(h)/Music","music.note")]
            var areas:[StorageArea]=[]
            for spec in specs{let s=itemSize(spec.1);if s>0{areas.append(StorageArea(id:spec.1,name:spec.0,path:spec.1,bytes:s,icon:spec.2))};out.append(contentsOf:reviewChildren(in:spec.1,label:spec.0))}
            out.sort{$0.bytes>$1.bytes};areas.sort{$0.bytes>$1.bytes}
            await MainActor.run{self.findings=out;self.storageAreas=areas;self.scanning=false;self.hasScanned=true}
        }
    }
    func delete(_ targets:[Finding]){var errors:[String]=[];for t in targets{do{let u=URL(fileURLWithPath:t.path);if t.kind == .review{_=try fm.trashItem(at:u,resultingItemURL:nil)}else{try fm.removeItem(at:u)}}catch{errors.append("\(t.name): \(error.localizedDescription)")}};lastError=errors.isEmpty ? nil:errors.joined(separator:"\n");scan()}
    func reveal(_ path:String){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])}
}

struct ContentView:View {
    @StateObject private var scanner=Scanner();@State private var page:Page? = .nuking;@State private var selected=Set<String>();@State private var showingPrivacy=false;@State private var confirmingDelete=false;@State private var showingError=false;@State private var explainedFinding:Finding?;@State private var explainedGroup:FindingGroup?
    @AppStorage("ignoredPaths") private var ignoredStore="";@AppStorage("excludedNukePaths") private var excludedStore=""
    private var ignored:Set<String>{Set(ignoredStore.split(separator:"\n").map(String.init))};private var excluded:Set<String>{Set(excludedStore.split(separator:"\n").map(String.init))};private var activePage:Page{page ?? .nuking}
    private var nukeItems:[Finding]{scanner.findings.filter{$0.kind == .nuke && !ignored.contains($0.path)}};private var reviewItems:[Finding]{scanner.findings.filter{$0.kind == .review && !ignored.contains($0.path)}};private var ignoredItems:[Finding]{scanner.findings.filter{ignored.contains($0.path)}}
    private var visible:[Finding]{switch activePage{case .nuking:return nukeItems;case .review:return reviewItems;case .ignored:return ignoredItems}}
    private var selectedItems:[Finding]{scanner.findings.filter{selected.contains($0.path)}};private var selectedBytes:Int64{selectedItems.reduce(0){$0+$1.bytes}};private var nukeBytes:Int64{nukeItems.reduce(0){$0+$1.bytes}};private var reviewBytes:Int64{reviewItems.reduce(0){$0+$1.bytes}};private var ignoredBytes:Int64{ignoredItems.reduce(0){$0+$1.bytes}};private var allVisibleSelected:Bool{!visible.isEmpty && visible.allSatisfy{selected.contains($0.path)}}
    private var nukeGroups:[FindingGroup]{
        var buckets:[String:[Finding]]=[:]
        for f in nukeItems { let n=f.name.lowercased();let key=n.contains("chrome") ? "Chrome":n.contains("claude") ? "Claude":(n.contains("adobe") || n.contains("creative cloud")) ? "Adobe":n.contains("codex") ? "Codex":n.contains("homebrew") ? "Homebrew":n.contains("yarn") ? "Yarn":f.name;buckets[key,default:[]].append(f) }
        return buckets.map{key,value in FindingGroup(id:key,name:key,summary:groupSummary(key,value),findings:value.sorted{$0.bytes>$1.bytes})}.sorted{$0.bytes>$1.bytes}
    }
    var body:some View{
        NavigationSplitView{sidebar.navigationSplitViewColumnWidth(min:190,ideal:220,max:250)}detail:{detail}.frame(minWidth:860,minHeight:580)
            .toolbar{ToolbarItem(placement:.primaryAction){Button(action:runScan){Label(scanner.scanning ? "Scanning…":"Scan",systemImage:"arrow.clockwise")}.disabled(scanner.scanning)}}
            .sheet(isPresented:$showingPrivacy){PrivacyView()}
            .sheet(item:$explainedFinding){f in FindingExplanationView(finding:f,reveal:{scanner.reveal(f.path)})}
            .sheet(item:$explainedGroup){g in GroupExplanationView(group:g,reveal:{if let p=g.findings.first?.path{scanner.reveal(p)}})}
            .confirmationDialog(activePage == .review ? "Move \(formatted(selectedBytes)) to Trash?":"Nuke \(formatted(selectedBytes))?",isPresented:$confirmingDelete,titleVisibility:.visible){Button(activePage == .review ? "Move to Trash":"Nuke \(formatted(selectedBytes))",role:.destructive){scanner.delete(selectedItems);selected.removeAll()};Button("Cancel",role:.cancel){}}message:{Text(activePage == .review ? "You can recover these items from Trash.":"Known regenerable data will be permanently removed.")}
            .alert("Some items couldn't be removed",isPresented:$showingError){Button("OK") {}}message:{Text(scanner.lastError ?? "Unknown error")}
            .onChange(of:page){_,_ in syncSelection()}.onChange(of:scanner.findings){_,_ in syncSelection()}.onChange(of:scanner.lastError){_,v in if v != nil{showingError=true}}
    }
    private var sidebar:some View{VStack(alignment:.leading,spacing:0){VStack(alignment:.leading,spacing:3){Text("NUKE").font(.system(size:22,weight:.bold));Text("See what's eating your Mac.").font(.caption).foregroundStyle(.secondary)}.padding(16);List(selection:$page){side(.nuking,nukeBytes);side(.review,reviewBytes);side(.ignored,ignoredBytes)}.listStyle(.sidebar);Spacer();Button{showingPrivacy=true}label:{Label("Privacy",systemImage:"hand.raised")}.buttonStyle(.plain).padding(16)}}
    private func side(_ p:Page,_ b:Int64)->some View{Label{HStack{Text(p.rawValue);Spacer();if scanner.hasScanned{Text(formatted(b)).foregroundStyle(.secondary)}}}icon:{Image(systemName:p.icon)}.tag(p)}
    private var detail:some View{ZStack{VStack(spacing:0){if !scanner.hasScanned && !scanner.scanning{welcome}else{header;if activePage == .review && !scanner.storageAreas.isEmpty{storageStrip};items}}.background(Color(nsColor:.windowBackgroundColor));if scanner.scanning{overlay}}}
    private var welcome:some View{VStack(spacing:16){Image(systemName:"internaldrive").font(.system(size:42)).foregroundStyle(.secondary);Text("See what's eating your Mac.").font(.system(size:30,weight:.semibold));Text("NUKE shows what is using your storage, explains it, then lets you decide what goes.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth:520);Button("Scan Mac",action:runScan).buttonStyle(.borderedProminent).controlSize(.large);Label("Scans locally. Nothing is uploaded.",systemImage:"lock.fill").font(.caption).foregroundStyle(.tertiary)}.frame(maxWidth:.infinity,maxHeight:.infinity)}
    private var overlay:some View{ZStack{Color(nsColor:.windowBackgroundColor).opacity(0.94).ignoresSafeArea();VStack(spacing:18){ProgressView().controlSize(.large);Text("Scanning your Mac…").font(.title2).fontWeight(.semibold);Text("Finding what's using your storage.").foregroundStyle(.secondary);ProgressView().progressViewStyle(.linear).frame(width:300)}}}
    private var header:some View{HStack(spacing:24){VStack(alignment:.leading,spacing:5){switch activePage{case .nuking:Text("\(formatted(nukeBytes)) worth nuking.").font(.system(size:34,weight:.semibold));Text("See who ate it, why it's here, and what happens if it goes.").foregroundStyle(.secondary);case .review:Text("\(formatted(reviewBytes)) to review.").font(.system(size:34,weight:.semibold));Text("Large files and uncertain app data. Nothing here is selected for you.").foregroundStyle(.secondary);case .ignored:Text("\(formatted(ignoredBytes)) ignored.").font(.system(size:34,weight:.semibold));Text("NUKE remembers to leave these alone.").foregroundStyle(.secondary)}};Spacer();if activePage != .ignored && !selected.isEmpty{Button(activePage == .review ? "Trash \(formatted(selectedBytes))":"Nuke \(formatted(selectedBytes))"){confirmingDelete=true}.buttonStyle(.borderedProminent).controlSize(.large)}}.padding(.horizontal,28).padding(.vertical,24)}
    private var storageStrip:some View{ScrollView(.horizontal,showsIndicators:false){HStack(spacing:10){ForEach(scanner.storageAreas){a in Button{scanner.reveal(a.path)}label:{HStack(spacing:9){Image(systemName:a.icon);VStack(alignment:.leading,spacing:1){Text(a.name).fontWeight(.medium);Text(formatted(a.bytes)).font(.caption).foregroundStyle(.secondary)}}.padding(.horizontal,12).padding(.vertical,9).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}}.padding(.horizontal,28).padding(.bottom,12)}}
    @ViewBuilder private var items:some View{
        if activePage == .nuking && !nukeGroups.isEmpty { List { HStack{Button(action:toggleAll){Image(systemName:allVisibleSelected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless);Text("Select all");Spacer();Text("\(nukeGroups.count) apps · \(nukeItems.count) items").foregroundStyle(.secondary)}.font(.caption).padding(.vertical,3);ForEach(nukeGroups){g in GroupRow(group:g,selected:g.findings.allSatisfy{selected.contains($0.path)},toggle:{toggleGroup(g)},explain:{explainedGroup=g})} }.listStyle(.inset)
        } else if visible.isEmpty { ContentUnavailableView(activePage == .ignored ? "Nothing ignored":"Nothing here",systemImage:"checkmark.circle").frame(maxWidth:.infinity,maxHeight:.infinity)
        } else { List { if activePage != .ignored{HStack{Button(action:toggleAll){Image(systemName:allVisibleSelected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless);Text("Select all");Spacer();Text("\(visible.count) items").foregroundStyle(.secondary)}.font(.caption).padding(.vertical,3)};ForEach(visible){f in FindingRow(finding:f,selected:selected.contains(f.path),selectable:activePage != .ignored,toggle:{toggle(f)},explain:{explainedFinding=f}).contextMenu{Button("Explain"){explainedFinding=f};Button("Show in Finder"){scanner.reveal(f.path)};Divider();Button(activePage == .ignored ? "Stop Ignoring":"Ignore"){toggleIgnored(f.path)}}} }.listStyle(.inset) }
    }
    private func runScan(){selected.removeAll();scanner.scan()}
    private func toggle(_ f:Finding){if selected.contains(f.path){selected.remove(f.path)}else{selected.insert(f.path)};if f.kind == .nuke{var s=excluded;if selected.contains(f.path){s.remove(f.path)}else{s.insert(f.path)};excludedStore=s.sorted().joined(separator:"\n")}}
    private func toggleGroup(_ g:FindingGroup){let all=g.findings.allSatisfy{selected.contains($0.path)};var s=excluded;for f in g.findings{if all{selected.remove(f.path);s.insert(f.path)}else{selected.insert(f.path);s.remove(f.path)}};excludedStore=s.sorted().joined(separator:"\n")}
    private func toggleAll(){let wasAll=allVisibleSelected;if wasAll{visible.forEach{selected.remove($0.path)}}else{visible.forEach{selected.insert($0.path)}};if activePage == .nuking{var s=excluded;if wasAll{visible.forEach{s.insert($0.path)}}else{visible.forEach{s.remove($0.path)}};excludedStore=s.sorted().joined(separator:"\n")}}
    private func toggleIgnored(_ p:String){var s=ignored;if s.contains(p){s.remove(p)}else{s.insert(p);selected.remove(p)};ignoredStore=s.sorted().joined(separator:"\n")}
    private func syncSelection(){if activePage == .nuking{selected=Set(nukeItems.filter{!excluded.contains($0.path)}.map(\.path))}else{selected.removeAll()}}
}

struct GroupRow:View{let group:FindingGroup;let selected:Bool;let toggle:()->Void;let explain:()->Void;var body:some View{HStack(spacing:12){Button(action:toggle){Image(systemName:selected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless).frame(width:26);VStack(alignment:.leading,spacing:4){Text(group.name).fontWeight(.semibold);Text(group.summary).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading);Text(formatted(group.bytes)).font(.system(.body,design:.monospaced,weight:.semibold)).monospacedDigit().frame(width:110,alignment:.trailing);Button("Explain",action:explain).buttonStyle(.borderless).font(.caption).frame(width:58,alignment:.trailing)}.padding(.vertical,7)}}
struct FindingRow:View{let finding:Finding;let selected:Bool;let selectable:Bool;let toggle:()->Void;let explain:()->Void;var body:some View{HStack(spacing:12){if selectable{Button(action:toggle){Image(systemName:selected ? "checkmark.square.fill":"square")}.buttonStyle(.borderless).frame(width:26)}else{Color.clear.frame(width:26,height:1)};VStack(alignment:.leading,spacing:4){Text(finding.name).fontWeight(.medium);Text(finding.what).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading);Text(formatted(finding.bytes)).font(.system(.body,design:.monospaced,weight:.semibold)).monospacedDigit().frame(width:110,alignment:.trailing);Button("Explain",action:explain).buttonStyle(.borderless).font(.caption).frame(width:58,alignment:.trailing)}.padding(.vertical,5)}}

struct GroupExplanationView:View{
    let group:FindingGroup;let reveal:()->Void;@Environment(\.dismiss) private var dismiss
    var body:some View{VStack(alignment:.leading,spacing:20){Text(groupHeadline(group)).font(.system(size:25,weight:.semibold));Text(groupStory(group)).font(.body).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true);Divider();VStack(alignment:.leading,spacing:10){Text("What NUKE found").fontWeight(.semibold);ForEach(group.findings){f in HStack(alignment:.firstTextBaseline){VStack(alignment:.leading,spacing:2){Text(f.name).fontWeight(.medium);Text(f.what).font(.caption).foregroundStyle(.secondary)};Spacer();Text(formatted(f.bytes)).monospacedDigit().foregroundStyle(.secondary)}}};Spacer();HStack{Button("Show largest in Finder",action:reveal);Spacer();Button("Done"){dismiss()}.keyboardShortcut(.defaultAction)}}.padding(30).frame(width:600,height:460)}
}
struct FindingExplanationView:View{let finding:Finding;let reveal:()->Void;@Environment(\.dismiss) private var dismiss;var body:some View{VStack(alignment:.leading,spacing:20){Text(singleHeadline(finding)).font(.system(size:25,weight:.semibold));Text(singleStory(finding)).foregroundStyle(.secondary);Divider();Text(shortPath(finding.path)).font(.callout.monospaced()).textSelection(.enabled).foregroundStyle(.secondary);Spacer();HStack{Button("Show in Finder",action:reveal);Spacer();Button("Done"){dismiss()}.keyboardShortcut(.defaultAction)}}.padding(30).frame(width:570,height:340)}}
struct PrivacyView:View{@Environment(\.dismiss) private var dismiss;var body:some View{VStack(alignment:.leading,spacing:18){Image(systemName:"hand.raised.fill").font(.system(size:30));Text("Your files stay yours.").font(.title2).fontWeight(.semibold);Text("NUKE scans locally. It doesn't upload your files or require an account.").foregroundStyle(.secondary);Button("Done"){dismiss()}.frame(maxWidth:.infinity,alignment:.trailing)}.padding(28).frame(width:440)}}

private func groupSummary(_ name:String,_ findings:[Finding])->String{switch name{case "Chrome":return "Browser cache, website cache and local downloads";case "Claude":return "Local environment and temporary app data";case "Adobe":return "Diagnostic logs from Adobe apps";case "Codex":return "Temporary working data";case "Homebrew":return "Downloaded installers and packages";case "Yarn":return "Downloaded JavaScript packages";default:return findings.first?.what ?? "Regenerable app data"}}
private func groupHeadline(_ g:FindingGroup)->String{"\(g.name) has quietly eaten \(formatted(g.bytes))."}
private func groupStory(_ g:FindingGroup)->String{switch g.name{case "Chrome":return "NUKE found \(formatted(g.bytes)) of regenerable Chrome data across browser cache, website workers and local downloads. Removing it won't delete your Chrome profiles, bookmarks, passwords or history. Chrome and websites rebuild what they need as you browse, although offline website content may need to download again.";case "Claude":let vm=g.findings.first{$0.name.lowercased().contains("vm")};return "\(vm.map{"\(formatted($0.bytes)) of that is a downloadable virtual machine. "} ?? "")Removing this data won't uninstall Claude or delete your chats. Claude recreates its caches and may download the computer environment again when you use it.";case "Adobe":return "These are diagnostic logs Adobe apps have accumulated, not your Photoshop files or creative projects. Removing them gives the space back; Adobe simply writes fresh logs when it needs them.";case "Codex":return "This is temporary working data, not your projects or code. Removing it gives you the space back and Codex recreates whatever it needs later.";case "Homebrew":return "These are packages and installers Homebrew kept after downloading them. Removing them doesn't uninstall your software. Homebrew downloads a package again if it ever needs it.";case "Yarn":return "These are downloaded package files Yarn keeps to speed up future installs. Your projects stay untouched. Yarn downloads packages again if they're needed.";default:return g.findings.map{$0.consequence}.joined(separator:" ")}}
private func singleHeadline(_ f:Finding)->String{"\(f.name) is using \(formatted(f.bytes))."}
private func singleStory(_ f:Finding)->String{"\(f.what) \(f.consequence)"}
private func shortPath(_ p:String)->String{p.replacingOccurrences(of:FileManager.default.homeDirectoryForCurrentUser.path,with:"~")}
private func formatted(_ b:Int64)->String{ByteCountFormatter.string(fromByteCount:b,countStyle:.file)}