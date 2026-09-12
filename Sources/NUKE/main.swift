import SwiftUI
import AppKit

@main
struct NukeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 980, height: 720)
    }
}

enum Safety: String, CaseIterable, Sendable { case nuke="NUKE", review="REVIEW", keep="KEEP" }
struct Finding: Identifiable, Hashable, Sendable { let id=UUID(); let name:String; let detail:String; let path:String; let bytes:Int64; let safety:Safety; let regenerable:Bool }

nonisolated func folderSize(_ path:String)->Int64 {
    let fm=FileManager.default; var dir:ObjCBool=false
    guard fm.fileExists(atPath:path,isDirectory:&dir) else{return 0}
    if !dir.boolValue{return (try? fm.attributesOfItem(atPath:path)[.size] as? NSNumber)?.int64Value ?? 0}
    guard let e=fm.enumerator(at:URL(fileURLWithPath:path),includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey],options:[.skipsHiddenFiles]) else{return 0}
    var n:Int64=0; for case let u as URL in e { if let v=try? u.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]),v.isRegularFile==true{n += Int64(v.fileSize ?? 0)} }; return n
}

@MainActor final class Scanner:ObservableObject {
    @Published var findings:[Finding]=[]; @Published var scanning=false; @Published var progress="Ready to scan"; @Published var lastFreed:Int64=0
    private let fm=FileManager.default; private var home:String{fm.homeDirectoryForCurrentUser.path}
    var nukeBytes:Int64{findings.filter{$0.safety == .nuke}.reduce(0){$0+$1.bytes}}
    var reviewBytes:Int64{findings.filter{$0.safety == .review}.reduce(0){$0+$1.bytes}}
    func scan(){
        scanning=true; progress="Looking under the couch…"; lastFreed=0; let h=home
        Task.detached(priority:.userInitiated){
            let rules:[(String,String,String,Safety,Bool)]=[
                ("Google Chrome","Browser cache · recreated automatically","\(h)/Library/Caches/Google",.nuke,true),
                ("Chrome on-device model","Downloaded local model · Chrome can fetch it again","\(h)/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel",.nuke,true),
                ("Chrome · Default","Offline website data · recreated as you browse","\(h)/Library/Application Support/Google/Chrome/Default/Service Worker",.nuke,true),
                ("Chrome · Profile 1","Offline website data · recreated as you browse","\(h)/Library/Application Support/Google/Chrome/Profile 1/Service Worker",.nuke,true),
                ("Chrome · Profile 2","Offline website data · recreated as you browse","\(h)/Library/Application Support/Google/Chrome/Profile 2/Service Worker",.nuke,true),
                ("Claude local VM","Local environment · Claude can download it again","\(h)/Library/Application Support/Claude/vm_bundles",.nuke,true),
                ("Claude cache","Temporary application cache","\(h)/Library/Application Support/Claude/Cache",.nuke,true),
                ("Claude code cache","Compiled app cache · recreated automatically","\(h)/Library/Application Support/Claude/Code Cache",.nuke,true),
                ("Adobe logs","Diagnostic logs · not your projects","\(h)/Library/Logs/Adobe",.nuke,true),
                ("Creative Cloud logs","Creative Cloud diagnostic logs","\(h)/Library/Logs/CreativeCloud",.nuke,true),
                ("Codex cache","Temporary Codex data","\(h)/Library/Caches/com.openai.codex",.nuke,true),
                ("Homebrew cache","Downloaded package cache","\(h)/Library/Caches/Homebrew",.nuke,true),
                ("Yarn cache","Downloaded package cache","\(h)/Library/Caches/Yarn",.nuke,true),
                ("Downloads","Your files · look before you launch","\(h)/Downloads",.review,false)]
            var out:[Finding]=[]
            for r in rules{let s=folderSize(r.2);if s>0{out.append(Finding(name:r.0,detail:r.1,path:r.2,bytes:s,safety:r.3,regenerable:r.4))}}
            let root="\(h)/Library/Caches"; if let kids=try? FileManager.default.contentsOfDirectory(atPath:root){let known=Set(out.map{$0.path});for k in kids{let p=root+"/"+k;if known.contains(p){continue};let s=folderSize(p);if s>=250_000_000{out.append(Finding(name:k,detail:"Large app cache · review if you don't recognize it",path:p,bytes:s,safety:.review,regenerable:false))}}}
            out.sort{$0.bytes>$1.bytes}; await MainActor.run{self.findings=out;self.scanning=false;self.progress="Scan complete"}
        }
    }
    func nukeSafe(){let t=findings.filter{$0.safety == .nuke && $0.regenerable};var f:Int64=0;for x in t{do{try fm.removeItem(atPath:x.path);f+=x.bytes}catch{}};lastFreed=f;scan()}
    func reveal(_ f:Finding){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:f.path)])}
}

private let acid=Color(red:0.87,green:1,blue:0)
private let ink=Color(red:0.035,green:0.035,blue:0.035)

struct ContentView:View {
    @StateObject private var scanner=Scanner(); @State private var privacy=false; @State private var tab:Safety?=nil
    var shown:[Finding]{tab == nil ? scanner.findings:scanner.findings.filter{$0.safety==tab}}
    var body:some View{
        ZStack{ink.ignoresSafeArea();VStack(spacing:0){
            HStack(spacing:18){Text("NUKE.").font(.system(size:24,weight:.black,design:.rounded));Spacer();Button{privacy=true}{Label("Privacy",systemImage:"lock.fill")}.buttonStyle(GhostButton());Button(action:scanner.scan){Label(scanner.scanning ? "SCANNING":"SCAN",systemImage:"arrow.clockwise")}.buttonStyle(GhostButton()).disabled(scanner.scanning)}.padding(.horizontal,30).frame(height:72).overlay(alignment:.bottom){Rectangle().fill(Color.white.opacity(.08)).frame(height:1)}
            ScrollView{VStack(alignment:.leading,spacing:26){
                HStack(alignment:.bottom){VStack(alignment:.leading,spacing:8){Text(scanner.findings.isEmpty ? "READY WHEN YOU ARE":"READY TO NUKE").font(.system(size:10,weight:.bold)).tracking(2).foregroundStyle(.secondary);HStack(alignment:.firstTextBaseline,spacing:8){Text(scanner.findings.isEmpty ? "—":ByteCountFormatter.string(fromByteCount:scanner.nukeBytes,countStyle:.file).replacingOccurrences(of:" GB",with:"" )).font(.system(size:70,weight:.bold,design:.rounded)).tracking(-4);if !scanner.findings.isEmpty{Text("GB").font(.title2.bold()).foregroundStyle(.secondary)}};Text(scanner.findings.isEmpty ? "Find what's eating your Mac.":"Known junk. Safe to regenerate.").foregroundStyle(.secondary)};Spacer();Button(scanner.findings.isEmpty ? "SCAN MY MAC →":"NUKE \(ByteCountFormatter.string(fromByteCount:scanner.nukeBytes,countStyle:.file)) →"){scanner.findings.isEmpty ? scanner.scan():scanner.nukeSafe()}.buttonStyle(NukeButton()).disabled(scanner.scanning || (!scanner.findings.isEmpty && scanner.nukeBytes==0))}.padding(.top,22)
                if scanner.scanning{ProgressView().tint(acid).scaleEffect(x:1,y:1.5).frame(maxWidth:.infinity)}
                if scanner.lastFreed>0{HStack{Text("WOOF.").font(.title2.black());Text("\(ByteCountFormatter.string(fromByteCount:scanner.lastFreed,countStyle:.file)) nuked.").foregroundStyle(.secondary)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(acid.opacity(.08),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(acid.opacity(.25)))}
                HStack(spacing:7){Chip("ALL",tab==nil){tab=nil};ForEach(Safety.allCases,id:\.self){s in Chip(s.rawValue,tab==s){tab=s}};Spacer();if scanner.reviewBytes>0{Text("\(ByteCountFormatter.string(fromByteCount:scanner.reviewBytes,countStyle:.file)) needs review").font(.caption).foregroundStyle(.secondary)}}
                if scanner.findings.isEmpty && !scanner.scanning{EmptyState(scan:scanner.scan)} else {LazyVStack(spacing:0){ForEach(shown){f in FindingRow(f:f,reveal:{scanner.reveal(f)})}}.background(Color.white.opacity(.025),in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(Color.white.opacity(.08)))}
            }.padding(.horizontal,36).padding(.vertical,24)}
            HStack(spacing:8){Circle().fill(acid).frame(width:6,height:6);Text("100% LOCAL").font(.system(size:10,weight:.bold)).tracking(1);Text("·  NO UPLOADS  ·  NO ACCOUNT").font(.system(size:10)).foregroundStyle(.secondary);Spacer();Text(scanner.progress).font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,30).frame(height:48).background(Color.white.opacity(.025)).overlay(alignment:.top){Rectangle().fill(Color.white.opacity(.08)).frame(height:1)}
        }}.preferredColorScheme(.dark).sheet(isPresented:$privacy){PrivacyView()}
    }
}

struct EmptyState:View{let scan:()->Void;var body:some View{VStack(spacing:16){ZStack{Circle().stroke(Color.white.opacity(.08),lineWidth:1).frame(width:100,height:100);Image(systemName:"sparkles").font(.system(size:38)).foregroundStyle(acid)};Text("Nothing scanned yet.").font(.title2.bold());Text("NUKE reads storage metadata locally and tells you what can go.\nNothing leaves this Mac.").multilineTextAlignment(.center).foregroundStyle(.secondary);Button("START SCAN",action:scan).buttonStyle(GhostButton())}.frame(maxWidth:.infinity).padding(.vertical,60)}}
struct Chip:View{let title:String;let active:Bool;let action:()->Void;init(_ t:String,_ a:Bool,_ x:@escaping()->Void){title=t;active=a;action=x}var body:some View{Button(title,action:action).font(.system(size:10,weight:.bold)).buttonStyle(.plain).padding(.horizontal,12).padding(.vertical,7).background(active ? Color.white:Color.white.opacity(.04),in:RoundedRectangle(cornerRadius:7)).foregroundStyle(active ? ink:Color.secondary).overlay(RoundedRectangle(cornerRadius:7).stroke(Color.white.opacity(.09)))}}
struct FindingRow:View{let f:Finding;let reveal:()->Void;var body:some View{HStack(spacing:15){ZStack{Circle().fill(f.safety == .nuke ? acid:Color.white.opacity(.08)).frame(width:28,height:28);Image(systemName:f.safety == .nuke ? "checkmark":"questionmark").font(.caption.bold()).foregroundStyle(f.safety == .nuke ? ink:Color.secondary)};VStack(alignment:.leading,spacing:4){Text(f.name).font(.system(size:14,weight:.semibold));Text(f.detail).font(.caption).foregroundStyle(.secondary);Text(f.path).font(.system(size:9,design:.monospaced)).foregroundStyle(.tertiary).lineLimit(1)};Spacer();Text(ByteCountFormatter.string(fromByteCount:f.bytes,countStyle:.file)).font(.system(size:13,weight:.bold,design:.monospaced));Text(f.safety.rawValue).font(.system(size:9,weight:.bold)).foregroundStyle(f.safety == .nuke ? acid:Color.secondary).frame(width:52);Button(action:reveal){Image(systemName:"folder").foregroundStyle(.secondary)}.buttonStyle(.plain)}.padding(.horizontal,17).frame(minHeight:78).overlay(alignment:.bottom){Rectangle().fill(Color.white.opacity(.06)).frame(height:1).padding(.leading,60)}}}
struct NukeButton:ButtonStyle{func makeBody(configuration:Configuration)->some View{configuration.label.font(.system(size:13,weight:.black)).foregroundStyle(ink).padding(.horizontal,22).frame(height:48).background(acid,in:RoundedRectangle(cornerRadius:10)).opacity(configuration.isPressed ? .7:1)}}
struct GhostButton:ButtonStyle{func makeBody(configuration:Configuration)->some View{configuration.label.font(.system(size:11,weight:.bold)).foregroundStyle(.primary).padding(.horizontal,13).frame(height:34).background(Color.white.opacity(configuration.isPressed ? .1:.045),in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.white.opacity(.09)))}}
struct PrivacyView:View{@Environment(\.dismiss)var dismiss;var body:some View{ZStack{ink.ignoresSafeArea();VStack(spacing:20){ZStack{Circle().fill(acid.opacity(.1)).frame(width:90,height:90);Image(systemName:"lock.shield.fill").font(.system(size:38)).foregroundStyle(acid)};Text("Your files stay yours.").font(.system(size:34,weight:.bold,design:.rounded));Text("NUKE needs Full Disk Access only for a deeper scan of macOS-protected folders. Nothing leaves your Mac. NUKE doesn't upload, store, or share your files or file data.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth:500);HStack(spacing:22){Label("100% local",systemImage:"checkmark");Label("No uploads",systemImage:"checkmark");Label("No account",systemImage:"checkmark")}.font(.caption.bold()).foregroundStyle(acid);HStack{Button("Not now"){dismiss()}.buttonStyle(GhostButton());Button("GRANT FULL DISK ACCESS →"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!);dismiss()}.buttonStyle(NukeButton())};Text("You can revoke access anytime in System Settings.").font(.caption2).foregroundStyle(.tertiary)}.padding(45)}}.frame(width:650,height:440).preferredColorScheme(.dark)}
