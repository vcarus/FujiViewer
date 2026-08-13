import Foundation

/// Persists heart marks in `.fujiviewer.json` inside the browsed folder.
///
/// Marks are keyed by file name so they survive copying or backing up the whole folder. Saves are
/// debounced by one second and flushed on demand (folder switch, app termination).
final class MarksStore {
    static let fileName = ".fujiviewer.json"

    private struct Payload: Codable {
        var marked: [String]
    }

    let fileURL: URL
    private var pendingWork: DispatchWorkItem?
    private var pendingMarks: Set<String>?

    init(folder: URL) {
        self.fileURL = folder.appendingPathComponent(MarksStore.fileName)
    }

    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            NSLog("[FujiViewer] could not parse \(fileURL.path)")
            return []
        }
        return Set(payload.marked)
    }

    /// Schedules a save one second from now, replacing any earlier pending save.
    func scheduleSave(_ marks: Set<String>) {
        pendingWork?.cancel()
        pendingMarks = marks
        let work = DispatchWorkItem { [weak self] in
            guard let self, let marks = self.pendingMarks else { return }
            self.pendingMarks = nil
            self.pendingWork = nil
            self.write(marks)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Writes a pending save immediately, if there is one.
    func flush() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let marks = pendingMarks else { return }
        pendingMarks = nil
        write(marks)
    }

    /// Moves the marks file to the Trash and drops any pending save.
    ///
    /// Only the confirmed "clear every heart" uses this. Ordinary saves keep unlinking the file in
    /// `write` — trashing it every time the last heart comes off would litter the Trash with dot
    /// files. Here the user is throwing away a whole culling pass, which deserves a way back.
    @discardableResult
    func trashFile() -> URL? {
        pendingWork?.cancel()
        pendingWork = nil
        pendingMarks = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            var inTrash: NSURL?
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: &inTrash)
            return inTrash as URL?
        } catch {
            // Not every volume has a Trash. The promise is that the marks are gone, so fall back to
            // deleting outright rather than leaving the file behind.
            NSLog("[FujiViewer] could not trash \(fileURL.path): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    private func write(_ marks: Set<String>) {
        do {
            if marks.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return
            }
            let payload = Payload(marked: marks.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[FujiViewer] could not save marks: \(error.localizedDescription)")
        }
    }
}
