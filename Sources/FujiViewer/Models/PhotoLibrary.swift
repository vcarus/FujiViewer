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

    /// Direction of the last move, used to bias prefetching.
    @ObservationIgnored private(set) var lastDirection = 1
    /// Timestamp of the key press that caused the current selection change.
    @ObservationIgnored private var navigationStart: CFAbsoluteTime?
    @ObservationIgnored private var marksStore: MarksStore?
    @ObservationIgnored private var isPresentingOpenPanel = false
    @ObservationIgnored private var statusClearWork: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.marksStore?.flush()
        }
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
        allPhotos = PhotoLibrary.scan(folder: url)
        rebuildVisiblePhotos()

        if let name, let index = photos.firstIndex(where: { $0.name == name }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
        lastDirection = 1
        navigationStart = CFAbsoluteTimeGetCurrent()

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
        do {
            try FileManager.default.trashItem(at: photo.url, resultingItemURL: nil)
        } catch {
            showStatus("Could not trash \(photo.name): \(error.localizedDescription)")
            return
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
