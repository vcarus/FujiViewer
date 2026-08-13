import AppKit
import SwiftUI

@main
struct FujiViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Owned here rather than by `ContentView` so the menu commands can reach it.
    @State private var ui = ViewerState()

    private var library: PhotoLibrary { .shared }

    init() {
        // `swift run` starts an unbundled binary: without a regular activation policy there is no
        // window in the Dock and the process never becomes key, so no keyboard events arrive.
        NSApplication.shared.setActivationPolicy(.regular)
        // A single-window viewer has no use for tabs, and this also drops the automatic
        // "Show Tab Bar" / "Show All Tabs" items from the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, ui: ui)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1600, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) { fileCommands }
            CommandGroup(replacing: .undoRedo) { undoCommands }
            CommandMenu("Photo") { photoCommands }
            CommandMenu("Go") { goCommands }
            CommandGroup(after: .sidebar) { viewCommands }
            CommandGroup(replacing: .help) { helpCommands }
        }
    }

    // MARK: Menu state

    /// Menu items carrying a bare-key equivalent are disabled while a sheet, alert or panel owns
    /// the keyboard. A disabled item does not swallow its key equivalent, so arrows and typing
    /// still reach the panel or alert that is up.
    private var bareKeysBlocked: Bool {
        ui.isModalActive || library.isPresentingOpenPanel
    }

    private var photoKeysBlocked: Bool {
        bareKeysBlocked || library.photos.isEmpty
    }

    // MARK: Menus

    @ViewBuilder
    private var fileCommands: some View {
        Button("Open Folder…") {
            library.presentOpenPanel()
        }
        .keyboardShortcut("o", modifiers: .command)

        Menu("Open Recent") {
            ForEach(library.recentFolders, id: \.self) { folder in
                Button(folder.lastPathComponent) {
                    library.openRecent(folder)
                }
                .help(folder.path)
            }
            Divider()
            Button("Clear Menu") {
                library.clearRecentFolders()
            }
        }
        .disabled(library.recentFolders.isEmpty)

        Divider()

        Button("Export Marked Photos…") {
            ui.showExportSheet = true
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(library.markedCount == 0)
    }

    @ViewBuilder
    private var undoCommands: some View {
        Button("Undo Move to Trash") {
            library.undoDelete()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!library.canUndoDelete)
    }

    @ViewBuilder
    private var photoCommands: some View {
        Toggle("Heart", isOn: Binding(
            get: { library.isCurrentMarked },
            set: { _ in
                guard ui.mainWindowIsQuiet() else { return }
                library.toggleMarkCurrent()
            }))
        .keyboardShortcut("f", modifiers: [])
        .disabled(photoKeysBlocked)

        Toggle("Marked Only", isOn: Binding(
            get: { library.filterMarkedOnly },
            set: { _ in
                guard ui.mainWindowIsQuiet() else { return }
                library.toggleFilter()
            }))
        .keyboardShortcut("l", modifiers: [])
        .disabled(bareKeysBlocked || library.allPhotos.isEmpty)

        // Deliberately without a key equivalent: it undoes a whole culling pass and cannot be taken
        // back, so it stays a menu-only, confirmed action.
        Button("Clear All Hearts…") {
            ui.requestClearMarks?()
        }
        .disabled(library.markedCount == 0)

        Divider()

        // The standard Edit ▸ Copy stays for text fields; it is disabled whenever no responder
        // implements copy(_:), and the menu system falls through a disabled key equivalent, so ⌘C
        // lands here while the photo canvas is up.
        Button("Copy Photo") {
            library.copyCurrentPhoto()
        }
        .keyboardShortcut("c", modifiers: .command)
        .disabled(library.photos.isEmpty)

        Button("Reveal in Finder") {
            library.revealCurrentInFinder()
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(library.photos.isEmpty)

        Menu("Open With") {
            ForEach(openWithApplications()) { application in
                Button(application.label) {
                    openCurrentPhoto(with: application.url)
                }
            }
        }
        .disabled(library.photos.isEmpty)

        Divider()

        Button("Move to Trash") {
            guard ui.mainWindowIsQuiet() else { return }
            ui.requestDelete?()
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(photoKeysBlocked)
    }

    @ViewBuilder
    private var goCommands: some View {
        Button("Previous Photo") { navigate(by: -1) }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(photoKeysBlocked)
        Button("Next Photo") { navigate(by: 1) }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(photoKeysBlocked)

        Divider()

        Button("Back 10 Photos") { navigate(by: -10) }
            .keyboardShortcut(.pageUp, modifiers: [])
            .disabled(photoKeysBlocked)
        Button("Forward 10 Photos") { navigate(by: 10) }
            .keyboardShortcut(.pageDown, modifiers: [])
            .disabled(photoKeysBlocked)

        Divider()

        Button("First Photo") {
            guard ui.mainWindowIsQuiet() else { return }
            library.goToFirst()
        }
        .keyboardShortcut(.home, modifiers: [])
        .disabled(photoKeysBlocked)
        Button("Last Photo") {
            guard ui.mainWindowIsQuiet() else { return }
            library.goToLast()
        }
        .keyboardShortcut(.end, modifiers: [])
        .disabled(photoKeysBlocked)
    }

    @ViewBuilder
    private var viewCommands: some View {
        // Plain "G" already toggles this in the key monitor; ⌘ events pass through it.
        Toggle("Grid View", isOn: Binding(
            get: { ui.mode == .grid },
            set: { isGrid in
                ui.mode = isGrid ? .grid : .loupe
                ui.zoomStatus = nil
            }))
        .keyboardShortcut("g", modifiers: .command)
        .disabled(library.photos.isEmpty)

        Toggle("Info Overlay", isOn: Binding(
            get: { ui.showExif },
            set: { isOn in
                guard ui.mainWindowIsQuiet() else { return }
                ui.showExif = isOn
            }))
        .keyboardShortcut("i", modifiers: [])
        .disabled(photoKeysBlocked)

        Divider()

        // Escape does this too, but only through the key monitor, which no menu can show.
        Button("Zoom to Fit") {
            ui.requestZoomToFit()
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(library.photos.isEmpty)

        // Space toggles fit ↔ 100% through the key monitor; a bare-space key equivalent renders
        // as the word "Space" in the menu, so the menu speaks Preview's dialect instead.
        Button("Actual Size") {
            if ui.mode == .grid {
                ui.mode = .loupe
            } else {
                ui.requestActualSize()
            }
        }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(library.photos.isEmpty)

        Toggle("Lock Zoom & Position", isOn: Binding(
            get: { ui.zoomLocked },
            set: { isOn in
                guard ui.mainWindowIsQuiet() else { return }
                ui.zoomLocked = isOn
            }))
        .keyboardShortcut("z", modifiers: [])
        .disabled(photoKeysBlocked)
    }

    @ViewBuilder
    private var helpCommands: some View {
        Button("Keyboard Shortcuts") {
            guard ui.mainWindowIsQuiet() else { return }
            ui.showShortcuts.toggle()
        }
        .keyboardShortcut("?", modifiers: [])
        .disabled(bareKeysBlocked)
    }

    // MARK: Menu actions

    private func navigate(by offset: Int) {
        guard ui.mainWindowIsQuiet() else { return }
        library.navigate(by: offset)
    }

    private struct OpenWithApplication: Identifiable {
        let url: URL
        let label: String

        var id: URL { url }
    }

    /// One LaunchServices lookup costs a few tenths of a millisecond and the command tree is
    /// rebuilt on every photo change, which is a path measured in single milliseconds. The answer
    /// only depends on the file type, and a folder holds one.
    private static var openWithCache: [String: [OpenWithApplication]] = [:]

    /// Applications that can open the current photo, the default one first and labelled.
    private func openWithApplications() -> [OpenWithApplication] {
        guard let photo = library.currentPhoto else { return [] }
        let fileType = photo.url.pathExtension.lowercased()
        if let cached = FujiViewerApp.openWithCache[fileType] { return cached }

        let workspace = NSWorkspace.shared
        var candidates = workspace.urlsForApplications(toOpen: photo.url)
        if let preferred = workspace.urlForApplication(toOpen: photo.url) {
            candidates.removeAll { $0 == preferred }
            candidates.insert(preferred, at: 0)
        }
        var seen: Set<String> = []
        let applications = candidates
            .filter { seen.insert($0.path).inserted }
            .prefix(8)
            .enumerated()
            .map { index, url in
                let name = FileManager.default.displayName(atPath: url.path)
                return OpenWithApplication(url: url, label: index == 0 ? "\(name) (default)" : name)
            }
        FujiViewerApp.openWithCache[fileType] = applications
        return applications
    }

    private func openCurrentPhoto(with application: URL) {
        guard let photo = library.currentPhoto else { return }
        NSWorkspace.shared.open([photo.url],
                                withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Folders opened from the Finder ("Open With", dropping a folder on the app icon, `open -a`).
    ///
    /// Note: a folder passed as a plain command-line argument cannot be supported — AppKit then
    /// treats the launch as a document open and SwiftUI's `WindowGroup` never creates its window.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        PhotoLibrary.shared.openDropped(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PhotoLibrary.shared.flushMarks()
    }
}

/// Console logging: `print` while attached to a terminal (`swift run`), `NSLog` otherwise so the
/// bundled app's messages show up in Console.app.
enum Log {
    private static let isTerminal = isatty(STDOUT_FILENO) == 1

    static func line(_ message: String) {
        if isTerminal {
            print(message)
        } else {
            NSLog("%@", message)
        }
    }
}
