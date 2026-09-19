import SwiftUI
import AppKit
@preconcurrency import ImageCaptureCore
import UniformTypeIdentifiers

enum IPhoneMediaKind: String, CaseIterable, Identifiable {
    case all = "All"
    case photo = "Photos"
    case video = "Videos"

    var id: String { rawValue }
}

struct IPhoneMediaItem: Identifiable {
    let id: String
    let file: ICCameraFile
    let name: String
    let bytes: Int64
    let kind: IPhoneMediaKind
    let createdAt: Date?
    let width: Int
    let height: Int
    let duration: Double
    let thumbnail: CGImage?
}

@MainActor
final class IPhoneManager: NSObject, ObservableObject {
    enum State: Equatable {
        case searching
        case opening(String)
        case locked(String)
        case loading(String, Int)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var items: [IPhoneMediaItem] = []
    @Published private(set) var deleting = false
    @Published private(set) var deletionError: String?

    private let browser = ICDeviceBrowser()
    private weak var camera: ICCameraDevice?

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
        browser.start()
    }

    deinit {
        browser.stop()
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var deviceName: String {
        switch state {
        case .opening(let name), .locked(let name), .loading(let name, _), .ready(let name): name
        case .searching, .failed: "iPhone"
        }
    }

    func requestThumbnails(for visibleItems: [IPhoneMediaItem]) {
        for item in visibleItems.prefix(80) where item.thumbnail == nil {
            item.file.requestThumbnail()
        }
    }

    func delete(ids: Set<String>) {
        guard let camera else { return }
        let files = items.filter { ids.contains($0.id) }.map(\.file)
        guard !files.isEmpty else { return }
        guard !camera.isLocked else {
            state = .locked(camera.name ?? "iPhone")
            return
        }

        deleting = true
        deletionError = nil
        camera.requestDeleteFiles(files)
    }

    func clearDeletionError() {
        deletionError = nil
    }

    private func attach(_ device: ICCameraDevice) {
        camera = device
        device.delegate = self
        let name = device.name ?? "iPhone"

        if device.isAccessRestrictedAppleDevice {
            state = .locked(name)
        } else {
            state = .opening(name)
            device.requestOpenSession()
        }
    }

    private func rebuildItems(from device: ICCameraDevice) {
        let name = device.name ?? "iPhone"
        let files = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        state = .loading(name, files.count)

        items = files.compactMap { file in
            guard let kind = mediaKind(for: file) else { return nil }
            return makeItem(from: file, kind: kind)
        }
        .sorted { lhs, rhs in
            if lhs.bytes == rhs.bytes {
                return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
            }
            return lhs.bytes > rhs.bytes
        }

        state = .ready(name)
    }

    private func makeItem(from file: ICCameraFile, kind: IPhoneMediaKind) -> IPhoneMediaItem {
        IPhoneMediaItem(
            id: "\(file.ptpObjectHandle)-\(file.name ?? "media")",
            file: file,
            name: file.originalFilename ?? file.name ?? "Untitled",
            bytes: Int64(file.fileSize),
            kind: kind,
            createdAt: file.fileCreationDate ?? file.creationDate,
            width: file.width,
            height: file.height,
            duration: file.duration,
            thumbnail: file.thumbnail
        )
    }

    private func mediaKind(for file: ICCameraFile) -> IPhoneMediaKind? {
        guard let uti = file.uti, let type = UTType(uti) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .photo }
        return nil
    }
}

extension IPhoneManager: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in self.attach(camera) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard self.camera === device else { return }
            self.camera = nil
            self.items = []
            self.state = .searching
        }
    }
}

extension IPhoneManager: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let error {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            self.camera = nil
            self.items = []
            self.state = .searching
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.rebuildItems(from: device) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in self.rebuildItems(from: camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor in self.rebuildItems(from: camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        Task { @MainActor in self.rebuildItems(from: camera) }
    }

    nonisolated func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    nonisolated func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {
        Task { @MainActor in self.rebuildItems(from: camera) }
    }

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.state = .locked(device.name ?? "iPhone") }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in
            self.state = .opening(camera.name ?? "iPhone")
            if camera.hasOpenSession {
                self.rebuildItems(from: camera)
            } else {
                camera.requestOpenSession()
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: (any Error)?) {
        Task { @MainActor in
            self.deleting = false
            if let error { self.deletionError = error.localizedDescription }
            self.rebuildItems(from: camera)
        }
    }
}

struct IPhoneView: View {
    @StateObject private var manager = IPhoneManager()
    @State private var filter: IPhoneMediaKind = .all
    @State private var selected = Set<String>()
    @State private var confirmingDelete = false

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 12)]

    private var visibleItems: [IPhoneMediaItem] {
        filter == .all ? manager.items : manager.items.filter { $0.kind == filter }
    }

    private var selectedItems: [IPhoneMediaItem] {
        manager.items.filter { selected.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        Group {
            switch manager.state {
            case .searching:
                emptyState(
                    icon: "cable.connector",
                    title: "Connect an iPhone",
                    message: "Plug it in with a cable, unlock it, then tap Trust on the iPhone. NUKE will read the photos and videos iOS exposes."
                )
            case .opening(let name):
                loadingState(title: "Opening \(name)", message: "Keep the iPhone unlocked while the session starts.")
            case .locked:
                emptyState(
                    icon: "lock.iphone",
                    title: "Unlock and trust this Mac",
                    message: "Unlock the iPhone and accept the Trust prompt. Media stays unavailable until iOS authorizes this Mac."
                )
            case .loading(let name, let count):
                loadingState(title: "Reading \(name)", message: "Cataloguing \(count.formatted()) exposed photos and videos.")
            case .ready:
                mediaBrowser
            case .failed(let message):
                emptyState(icon: "exclamationmark.triangle", title: "Couldn’t open the iPhone", message: message)
            }
        }
        .confirmationDialog(
            "Delete \(selected.count) item\(selected.count == 1 ? "" : "s") from \(manager.deviceName)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(formatted(selectedBytes))", role: .destructive) {
                manager.delete(ids: selected)
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This asks the iPhone to delete the selected originals. They may remain recoverable in Recently Deleted, depending on the device’s Photos settings.")
        }
        .alert(
            "Some items couldn’t be deleted",
            isPresented: Binding(
                get: { manager.deletionError != nil },
                set: { if !$0 { manager.clearDeletionError() } }
            )
        ) {
            Button("OK") { manager.clearDeletionError() }
        } message: {
            Text(manager.deletionError ?? "Unknown error")
        }
    }

    private var mediaBrowser: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(formatted(manager.totalBytes)) on \(manager.deviceName)")
                        .font(.system(size: 34, weight: .semibold))
                        .monospacedDigit()
                    Text("Photos and videos exposed by iOS, sorted largest first.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Media", selection: $filter) {
                    ForEach(IPhoneMediaKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()

            if visibleItems.isEmpty {
                ContentUnavailableView("No \(filter == .all ? "media" : filter.rawValue.lowercased())", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleItems) { item in
                            IPhoneMediaCard(
                                item: item,
                                selected: selected.contains(item.id),
                                toggle: {
                                    if selected.contains(item.id) { selected.remove(item.id) }
                                    else { selected.insert(item.id) }
                                },
                                loadThumbnail: { manager.requestThumbnails(for: [item]) }
                            )
                        }
                    }
                    .padding(20)
                }
                .onAppear { manager.requestThumbnails(for: visibleItems) }
                .onChange(of: filter) { _, _ in manager.requestThumbnails(for: visibleItems) }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selected.isEmpty ? "Nothing selected" : "\(selected.count) selected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(formatted(selectedBytes))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }
                Spacer()
                Button("Delete from iPhone") { confirmingDelete = true }
                    .buttonStyle(NukeButtonStyle())
                    .disabled(selected.isEmpty || manager.deleting)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 15)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func loadingState(title: String, message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(nukeYellow)
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 17) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 24, weight: .semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Text("Private app files and caches are sandboxed by iOS and aren’t exposed over USB.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IPhoneMediaCard: View {
    let item: IPhoneMediaItem
    let selected: Bool
    let toggle: () -> Void
    let loadThumbnail: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 9) {
                thumbnailView
                metadataView
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? nukeYellow.opacity(0.09) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? nukeYellow.opacity(0.55) : Color.primary.opacity(0.08))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onAppear(perform: loadThumbnail)
    }

    private var thumbnailView: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
                Group {
                    if let thumbnail = item.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .overlay {
                                Image(systemName: item.kind == .video ? "video" : "photo")
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 126)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            SelectionMark(selected: selected).padding(8)
        }
    }

    private var metadataView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(mediaDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(formatted(item.bytes))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
    }

    private var mediaDetail: String {
        if item.kind == .video, item.duration > 0 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = item.duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
            formatter.zeroFormattingBehavior = .pad
            return formatter.string(from: item.duration) ?? "Video"
        }
        if item.width > 0, item.height > 0 { return "\(item.width) × \(item.height)" }
        return item.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? item.kind.rawValue.dropLast().description
    }
}
