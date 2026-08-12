import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode {
    case loupe
    case grid
}

/// View-level state shared with the key handler.
@Observable
final class ViewerState {
    var mode: ViewMode = .loupe
    var showExif = false
    var gridColumns = 5

    /// One-shot zoom request handed to the loupe's scroll view.
    var zoomCommand = ZoomCommand()
    /// Latest zoom reported back by the loupe; `nil` until the first photo is on screen.
    var zoomStatus: ZoomStatus?

    @ObservationIgnored weak var window: NSWindow?

    var isZoomedIn: Bool {
        guard let zoomStatus else { return false }
        return !zoomStatus.isFitted
    }

    func requestZoomToggle() {
        zoomCommand = ZoomCommand(kind: .toggle, token: zoomCommand.token + 1)
    }

    func requestZoomToFit() {
        zoomCommand = ZoomCommand(kind: .fit, token: zoomCommand.token + 1)
    }
}

struct ContentView: View {
    let library: PhotoLibrary

    @State private var ui = ViewerState()
    @State private var isDropTargeted = false
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if library.folder == nil {
                EmptyStateView(title: "Drop a folder of photos here",
                               subtitle: "or press ⌘O to choose one") {
                    library.presentOpenPanel()
                }
            } else if library.photos.isEmpty {
                EmptyStateView(title: "No photos to show",
                               subtitle: library.allPhotos.isEmpty
                                   ? "\(library.folder?.lastPathComponent ?? "This folder") has no HIF/HEIC/JPEG files"
                                   : "Press L to leave the marked-only filter") {
                    library.presentOpenPanel()
                }
            } else {
                switch ui.mode {
                case .loupe:
                    LoupeView(library: library, ui: ui)
                case .grid:
                    GridView(library: library, ui: ui)
                }
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .padding(8)
                    .allowsHitTesting(false)
            }

            if let message = library.statusMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(WindowAccessor { window in
            guard ui.window !== window else { return }
            ui.window = window
            window.backgroundColor = .black
        })
        .navigationTitle(library.windowTitle)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
            library.flushMarks()
        }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let identifier = UTType.fileURL.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                url = direct
            }
            guard let url else { return }
            DispatchQueue.main.async {
                library.openDropped(url)
            }
        }
        return true
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
    }

    /// Returning `nil` consumes the event; returning the event passes it on.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Only act when our own window is key (an open panel or sheet must keep its keys).
        guard let window = ui.window, NSApp.keyWindow === window else { return event }
        // Never swallow typing.
        if let responder = window.firstResponder, responder is NSTextView { return event }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])

        if modifiers.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "o", modifiers == .command {
                library.presentOpenPanel()
                return nil
            }
            return event
        }
        guard !modifiers.contains(.control), !modifiers.contains(.option) else { return event }
        guard library.folder != nil, !library.photos.isEmpty else { return event }

        switch event.keyCode {
        case 123: // left
            library.navigate(by: -1)
            return nil
        case 124: // right
            library.navigate(by: 1)
            return nil
        case 126: // up
            library.navigate(by: ui.mode == .grid ? -max(1, ui.gridColumns) : -1)
            return nil
        case 125: // down
            library.navigate(by: ui.mode == .grid ? max(1, ui.gridColumns) : 1)
            return nil
        case 36, 76: // return, enter
            if ui.mode == .grid { ui.mode = .loupe }
            return nil
        case 49: // space
            if ui.mode == .grid {
                ui.mode = .loupe
            } else {
                ui.requestZoomToggle()
            }
            return nil
        case 51, 117: // delete, forward delete
            library.deleteCurrent()
            return nil
        case 53: // escape
            if ui.mode == .loupe, ui.isZoomedIn {
                ui.requestZoomToFit()
            } else if ui.mode == .grid {
                ui.mode = .loupe
            }
            return nil
        case 115: // home
            library.goToFirst()
            return nil
        case 119: // end
            library.goToLast()
            return nil
        case 116: // page up
            library.navigate(by: -10)
            return nil
        case 121: // page down
            library.navigate(by: 10)
            return nil
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g":
            ui.mode = ui.mode == .grid ? .loupe : .grid
            ui.zoomStatus = nil
        case "i":
            ui.showExif.toggle()
        case "f":
            library.toggleMarkCurrent()
        case "l":
            library.toggleFilter()
        default:
            // Swallow the rest so unhandled keys do not beep while browsing.
            return nil
        }
        return nil
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 20, weight: .medium))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Choose Folder…", action: onOpen)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window access

/// Hands back the `NSWindow` hosting the SwiftUI content.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onWindow(window) }
        }
    }
}
