import AppKit
import Foundation
import Observation

struct Photo: Identifiable, Hashable {
    let url: URL
    let name: String

    var id: URL { url }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
    }
}

/// Folder contents, selection, marks and filtering.
@Observable
final class PhotoLibrary {
    /// Shared with `AppDelegate`, which receives folders opened from the Finder before any view exists.
    static let shared = PhotoLibrary()

    static let supportedExtensions: Set<String> = ["hif", "heic", "heif", "jpg", "jpeg"]

    private(set) var folder: URL?
    private(set) var allPhotos: [Photo] = []
    /// The visible list: all photos, or only the marked ones when the filter is on.
    private(set) var photos: [Photo] = []
    private(set) var marked: Set<String> = []
    private(set) var filterMarkedOnly = false
    private(set) var currentIndex = 0
    private(set) var statusMessage: String?
    /// Folders opened before, newest first.
    private(set) var recentFolders: [URL] = []
    /// Observed by the menu: a bare-key equivalent must not fire while the panel owns the keyboard.
    private(set) var isPresentingOpenPanel = false

    /// One entry per photo this session moved to the Trash, oldest first.
    private var trashed: [TrashedPhoto] = []

    /// Direction of the last move, used to bias prefetching.
    @ObservationIgnored private(set) var lastDirection = 1
    /// Timestamp of the key press that caused the current selection change.
    @ObservationIgnored private var navigationStart: CFAbsoluteTime?
    @ObservationIgnored private var marksStore: MarksStore?
    @ObservationIgnored private var statusClearWork: DispatchWorkItem?
    @ObservationIgnored private var folderSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var rescanWork: DispatchWorkItem?

    private struct TrashedPhoto {
        let original: URL
        let inTrash: URL
        let wasMarked: Bool
    }

    private static let recentFoldersKey = "RecentFolders"
    /// Undo is session-only, so the stack just needs a sane ceiling.
    private static let maxTrashUndo = 50
    private static let maxRecentFolders = 10

    init() {
        recentFolders = (UserDefaults.standard.array(forKey: PhotoLibrary.recentFoldersKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.marksStore?.flush()
        }
    }

    deinit {
        folderSource?.cancel()
    }

    // MARK: Derived state

    var currentPhoto: Photo? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    var markedCount: Int { marked.count }

    /// Every marked photo in folder order, regardless of the current filter.
    var markedPhotos: [Photo] { allPhotos.filter { marked.contains($0.name) } }

    var isCurrentMarked: Bool {
        guard let photo = currentPhoto else { return false }
        return marked.contains(photo.name)
    }

    var canUndoDelete: Bool { !trashed.isEmpty }

    var windowTitle: String {
        guard folder != nil else { return "FujiViewer" }
        guard let photo = currentPhoto else {
            return "FujiViewer — \(folder?.lastPathComponent ?? "")"
        }
        var title = "\(photo.name) · \(currentIndex + 1)/\(photos.count)"
        if !marked.isEmpty { title += " · ♥\(marked.count)" }
        if filterMarkedOnly { title += " · marked only" }
        return title
    }

    func isMarked(_ photo: Photo) -> Bool { marked.contains(photo.name) }

    // MARK: Opening

    func presentOpenPanel() {
        guard !isPresentingOpenPanel else { return }
        isPresentingOpenPanel = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos"
        panel.directoryURL = folder
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isPresentingOpenPanel = false
            guard response == .OK, let url = panel.url else { return }
            self.open(folder: url)
        }
    }

    /// Recent entries go stale often here — a card gets ejected, a shoot folder gets renamed — so
    /// a dead one reports itself and drops off the list instead of opening an empty window.
    func openRecent(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            recentFolders.removeAll { $0.path == url.path }
            saveRecentFolders()
            showStatus("\(url.lastPathComponent) is not there any more")
            return
        }
        open(folder: url)
    }

    func clearRecentFolders() {
        recentFolders = []
        UserDefaults.standard.removeObject(forKey: PhotoLibrary.recentFoldersKey)
    }

    private func rememberRecentFolder(_ url: URL) {
        var list = recentFolders.filter { $0.path != url.path }
        list.insert(url, at: 0)
        recentFolders = Array(list.prefix(PhotoLibrary.maxRecentFolders))
        saveRecentFolders()
    }

    private func saveRecentFolders() {
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: PhotoLibrary.recentFoldersKey)
    }

    /// Handles a dropped folder, or a dropped image file (opens its folder and selects it).
    func openDropped(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            open(folder: url)
        } else if PhotoLibrary.supportedExtensions.contains(url.pathExtension.lowercased()) {
            open(folder: url.deletingLastPathComponent(), select: url.lastPathComponent)
        } else {
            showStatus("Not an image: \(url.lastPathComponent)")
        }
    }

    func open(folder url: URL, select name: String? = nil) {
        marksStore?.flush()
        ImagePipeline.shared.reset()

        let store = MarksStore(folder: url)
        marksStore = store
        folder = url
        marked = store.load()
        filterMarkedOnly = false
        // The entries name files in the folder being left behind.
        trashed = []
        allPhotos = PhotoLibrary.scan(folder: url)
        rebuildVisiblePhotos()

        if let name, let index = photos.firstIndex(where: { $0.name == name }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
        lastDirection = 1
        navigationStart = CFAbsoluteTimeGetCurrent()

        rememberRecentFolder(url)
        startWatching(url)

        if allPhotos.isEmpty {
            showStatus("No photos in \(url.lastPathComponent)")
        }
        Log.line("[FujiViewer] opened \(url.path): \(allPhotos.count) photos, \(marked.count) marked")
    }

    private static func scan(folder: URL) -> [Photo] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: folder,
                                                             includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            return []
        }
        return entries
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Photo.init(url:))
    }

    // MARK: Watching

    /// Keeps the list in step with the folder while the app is open (a card being copied in, files
    /// deleted in the Finder). The descriptor is `O_EVTONLY`, so it does not keep the volume busy.
    private func startWatching(_ url: URL) {
        stopWatching()
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .link],
                                                               queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRescan() }
        source.setCancelHandler { Darwin.close(descriptor) }
        folderSource = source
        source.resume()
    }

    private func stopWatching() {
        rescanWork?.cancel()
        rescanWork = nil
        folderSource?.cancel()
        folderSource = nil
    }

    /// A card copy fires an event per file; one rescan after things settle is enough.
    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescanFolder() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func rescanFolder() {
        guard let url = folder else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Keep the (now stale) list on screen rather than emptying the window.
            stopWatching()
            showStatus("Folder was removed")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let scanned = PhotoLibrary.scan(folder: url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.folder == url else { return }
                self.apply(scanned: scanned)
            }
        }
    }

    /// Our own trashing, mark saves and restores all fire events after the list was already
    /// updated, so the common case is an empty diff and no status at all.
    private func apply(scanned: [Photo]) {
        let oldNames = allPhotos.map(\.name)
        let newNames = scanned.map(\.name)
        guard oldNames != newNames else { return }

        let removed = Set(oldNames).subtracting(newNames)
        for photo in allPhotos where removed.contains(photo.name) {
            ImagePipeline.shared.forget(photo.url)
        }

        let anchor = currentPhoto
        allPhotos = scanned
        if !removed.isEmpty {
            let before = marked.count
            marked.subtract(removed)
            if marked.count != before { marksStore?.scheduleSave(marked) }
        }

        let wasFiltering = filterMarkedOnly
        rebuildVisiblePhotos()
        if wasFiltering && photos.isEmpty {
            filterMarkedOnly = false
            rebuildVisiblePhotos()
        }
        currentIndex = remapIndex(anchor: anchor)
        showStatus("Folder changed — \(allPhotos.count) photos")
    }

    // MARK: Navigation

    func navigate(by offset: Int) {
        guard !photos.isEmpty, offset != 0 else { return }
        let target = min(max(currentIndex + offset, 0), photos.count - 1)
        lastDirection = offset > 0 ? 1 : -1
        guard target != currentIndex else { return }
        navigationStart = CFAbsoluteTimeGetCurrent()
        currentIndex = target
    }

    func select(index: Int) {
        guard photos.indices.contains(index), index != currentIndex else { return }
        lastDirection = index >= currentIndex ? 1 : -1
        navigationStart = CFAbsoluteTimeGetCurrent()
        currentIndex = index
    }

    func goToFirst() { select(index: 0) }
    func goToLast() { select(index: max(0, photos.count - 1)) }

    /// Returns (and clears) the timestamp of the key press that started the pending switch.
    func consumeNavigationStart() -> CFAbsoluteTime? {
        defer { navigationStart = nil }
        return navigationStart
    }

    // MARK: Marks and filtering

    func toggleMarkCurrent() {
        guard let photo = currentPhoto else { return }
        if marked.contains(photo.name) {
            marked.remove(photo.name)
        } else {
            marked.insert(photo.name)
        }
        marksStore?.scheduleSave(marked)
        if filterMarkedOnly {
            let anchor = photo.name
            rebuildVisiblePhotos()
            if photos.isEmpty {
                filterMarkedOnly = false
                rebuildVisiblePhotos()
                showStatus("No marked photos left — showing all")
                currentIndex = allPhotos.firstIndex { $0.name == anchor } ?? min(currentIndex, max(0, photos.count - 1))
            } else if let index = photos.firstIndex(where: { $0.name == anchor }) {
                currentIndex = index
            } else {
                currentIndex = min(currentIndex, photos.count - 1)
            }
        }
    }

    /// Drops every heart in this folder and moves `.fujiviewer.json` to the Trash with them.
    ///
    /// The file goes immediately rather than on the usual one-second save debounce: the action is
    /// destructive and confirmed, so it must be gone by the time the user looks for it.
    func clearAllMarks() {
        guard !marked.isEmpty else { return }
        let count = marked.count
        let anchor = currentPhoto?.name
        marked.removeAll()
        marksStore?.trashFile()
        // Undoing a delete restores the heart it carried, which would write the file back out for a
        // photo the user just cleared. Forget those marks too.
        trashed = trashed.map { TrashedPhoto(original: $0.original, inTrash: $0.inTrash, wasMarked: false) }
        if filterMarkedOnly {
            filterMarkedOnly = false
            rebuildVisiblePhotos()
            if let anchor, let index = photos.firstIndex(where: { $0.name == anchor }) {
                currentIndex = index
            } else {
                currentIndex = min(currentIndex, max(0, photos.count - 1))
            }
            showStatus("Cleared \(count) heart\(count == 1 ? "" : "s") — showing all")
        } else {
            showStatus("Cleared \(count) heart\(count == 1 ? "" : "s")")
        }
    }

    func toggleFilter() {
        if !filterMarkedOnly && marked.isEmpty {
            showStatus("No marked photos")
            return
        }
        let anchor = currentPhoto
        filterMarkedOnly.toggle()
        rebuildVisiblePhotos()
        currentIndex = remapIndex(anchor: anchor)
        showStatus(filterMarkedOnly ? "Marked only (\(photos.count))" : "All photos (\(photos.count))")
    }

    /// Keeps the selection on the same photo, or on the nearest one that is still visible.
    private func remapIndex(anchor: Photo?) -> Int {
        guard !photos.isEmpty else { return 0 }
        guard let anchor else { return 0 }
        if let exact = photos.firstIndex(where: { $0.name == anchor.name }) { return exact }
        guard let anchorPosition = allPhotos.firstIndex(where: { $0.name == anchor.name }) else { return 0 }
        var positions: [String: Int] = [:]
        for (index, photo) in allPhotos.enumerated() { positions[photo.name] = index }
        var best = 0
        var bestDistance = Int.max
        for (index, photo) in photos.enumerated() {
            let distance = abs((positions[photo.name] ?? 0) - anchorPosition)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func rebuildVisiblePhotos() {
        photos = filterMarkedOnly ? allPhotos.filter { marked.contains($0.name) } : allPhotos
        if currentIndex >= photos.count {
            currentIndex = max(0, photos.count - 1)
        }
    }

    // MARK: Deleting

    func deleteCurrent() {
        guard let photo = currentPhoto else { return }
        let wasMarked = marked.contains(photo.name)
        var inTrash: NSURL?
        do {
            try FileManager.default.trashItem(at: photo.url, resultingItemURL: &inTrash)
        } catch {
            showStatus("Could not trash \(photo.name): \(error.localizedDescription)")
            return
        }
        if let inTrash = inTrash as URL? {
            trashed.append(TrashedPhoto(original: photo.url, inTrash: inTrash, wasMarked: wasMarked))
            if trashed.count > PhotoLibrary.maxTrashUndo { trashed.removeFirst() }
        }
        ImagePipeline.shared.forget(photo.url)
        allPhotos.removeAll { $0.url == photo.url }
        if marked.remove(photo.name) != nil {
            marksStore?.scheduleSave(marked)
        }
        let wasFiltering = filterMarkedOnly
        rebuildVisiblePhotos()
        if wasFiltering && photos.isEmpty {
            filterMarkedOnly = false
            rebuildVisiblePhotos()
            showStatus("No marked photos left — showing all")
        }
        navigationStart = CFAbsoluteTimeGetCurrent()
        currentIndex = min(currentIndex, max(0, photos.count - 1))
        showStatus("Moved \(photo.name) to Trash")
    }

    /// Moves the most recently trashed photo back and selects it again.
    func undoDelete() {
        guard let entry = trashed.popLast() else { return }
        let name = entry.original.lastPathComponent
        let manager = FileManager.default

        guard !manager.fileExists(atPath: entry.original.path) else {
            showStatus("\(name) is back in the folder already")
            return
        }
        do {
            try manager.moveItem(at: entry.inTrash, to: entry.original)
        } catch {
            showStatus("Could not restore \(name): \(error.localizedDescription)")
            return
        }

        let photo = Photo(url: entry.original)
        let position = allPhotos.firstIndex {
            $0.name.localizedStandardCompare(photo.name) == .orderedDescending
        } ?? allPhotos.count
        allPhotos.insert(photo, at: position)
        if entry.wasMarked {
            marked.insert(photo.name)
            marksStore?.scheduleSave(marked)
        }
        rebuildVisiblePhotos()
        if let index = photos.firstIndex(where: { $0.name == photo.name }) {
            navigationStart = CFAbsoluteTimeGetCurrent()
            currentIndex = index
        }
        showStatus("Restored \(name)")
    }

    // MARK: Sharing

    /// Puts both the file and its pixels on the pasteboard: the Finder pastes the file, an image
    /// editor pastes the photo.
    func copyCurrentPhoto() {
        guard let photo = currentPhoto else { return }
        var items: [NSPasteboardWriting] = [photo.url as NSURL]
        if let decoded = ImagePipeline.shared.bestCachedImage(photo.url) {
            items.append(NSImage(cgImage: decoded.cgImage,
                                 size: NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight)))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
        showStatus("Copied \(photo.name)")
    }

    func revealCurrentInFinder() {
        guard let photo = currentPhoto else { return }
        NSWorkspace.shared.activateFileViewerSelecting([photo.url])
    }

    // MARK: Status

    func showStatus(_ message: String) {
        statusMessage = message
        statusClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func flushMarks() {
        marksStore?.flush()
    }
}
