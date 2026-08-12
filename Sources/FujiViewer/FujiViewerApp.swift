import AppKit
import SwiftUI

@main
struct FujiViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var library: PhotoLibrary { .shared }

    init() {
        // `swift run` starts an unbundled binary: without a regular activation policy there is no
        // window in the Dock and the process never becomes key, so no keyboard events arrive.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1600, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    library.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
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
