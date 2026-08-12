import SwiftUI

/// The complete key list, shown by "?" and by Help ▸ Keyboard Shortcuts.
///
/// Every entry here also exists as a menu item; keep the two in step when adding a key.
struct ShortcutsOverlay: View {
    private struct ShortcutGroup: Identifiable {
        let title: String
        let entries: [(keys: String, action: String)]

        var id: String { title }
    }

    private let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Navigate", entries: [
            ("← →", "Previous / next photo"),
            ("↑ ↓", "Previous / next row in the grid"),
            ("⇞ ⇟", "Back / forward 10 photos"),
            ("↖ ↘", "First / last photo"),
            ("G / ⌘G", "Grid view"),
            ("↩", "Grid → loupe"),
        ]),
        ShortcutGroup(title: "Zoom", entries: [
            ("Space", "Fit ↔ 100%"),
            ("Double click", "Zoom to the click point"),
            ("Pinch", "Continuous zoom"),
            ("Drag", "Pan while zoomed in"),
            ("Z", "Lock zoom & position"),
            ("⌘0", "Zoom to fit"),
            ("⎋", "Zoom to fit, unlock"),
        ]),
        ShortcutGroup(title: "Mark & Cull", entries: [
            ("F", "Toggle heart"),
            ("L", "Marked only"),
            ("⌫", "Move to Trash"),
            ("⌘Z", "Undo move to Trash"),
            ("⌘E", "Export marked photos…"),
        ]),
        ShortcutGroup(title: "Photo", entries: [
            ("I", "Info overlay & histogram"),
            ("⌘C", "Copy photo"),
            ("⌘R", "Reveal in Finder"),
        ]),
        ShortcutGroup(title: "Window", entries: [
            ("⌘O", "Open folder"),
            ("?", "This list"),
            ("⎋", "Close this list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 17, weight: .semibold))

            HStack(alignment: .top, spacing: 34) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups.prefix(2)) { group in
                        column(group)
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups.dropFirst(2)) { group in
                        column(group)
                    }
                }
            }

            Text("Press ? or ⎋ to close")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func column(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(group.entries, id: \.keys) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.keys)
                        .font(.system(size: 11, weight: .medium).monospaced())
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(.primary)
                    Text(entry.action)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
