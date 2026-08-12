import XCTest
@testable import FujiViewer

final class PhotoLibraryTests: XCTestCase {

    /// A folder of `count` JPEGs named the way a camera names them.
    private func makeFolder(_ names: [String]) throws -> URL {
        let folder = try Fixtures.makeDirectory(self)
        for name in names {
            try Fixtures.writeJPEG(in: folder, named: name, width: 120, height: 80)
        }
        return folder
    }

    // MARK: Scanning

    func testScanSortsTheWayFinderDoes() throws {
        let folder = try makeFolder(["DSCF10.jpg", "DSCF2.jpg", "DSCF1.jpg"])
        let library = PhotoLibrary()

        library.open(folder: folder)

        XCTAssertEqual(library.allPhotos.map(\.name), ["DSCF1.jpg", "DSCF2.jpg", "DSCF10.jpg"],
                       "localizedStandardCompare orders numbers numerically, not lexically")
    }

    func testScanKeepsOnlySupportedExtensions() throws {
        let folder = try makeFolder(["a.jpg", "b.jpeg"])
        try Fixtures.write(Fixtures.makeImage(width: 60, height: 40),
                           to: folder.appendingPathComponent("c.heic"), type: .heic)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))

        let library = PhotoLibrary()
        library.open(folder: folder)

        XCTAssertEqual(library.allPhotos.map(\.name), ["a.jpg", "b.jpeg", "c.heic"])
    }

    func testOpeningSelectsTheRequestedPhoto() throws {
        let folder = try makeFolder(["a.jpg", "b.jpg", "c.jpg"])
        let library = PhotoLibrary()

        library.open(folder: folder, select: "b.jpg")

        XCTAssertEqual(library.currentPhoto?.name, "b.jpg")
        XCTAssertEqual(library.currentIndex, 1)
    }

    // MARK: Navigation

    func testNavigationClampsAtBothEnds() throws {
        let folder = try makeFolder(["a.jpg", "b.jpg", "c.jpg"])
        let library = PhotoLibrary()
        library.open(folder: folder)

        library.navigate(by: -1)
        XCTAssertEqual(library.currentIndex, 0, "already at the first photo")

        library.navigate(by: 99)
        XCTAssertEqual(library.currentIndex, 2, "cannot run past the last photo")

        library.goToFirst()
        XCTAssertEqual(library.currentIndex, 0)
        library.goToLast()
        XCTAssertEqual(library.currentIndex, 2)
    }

    // MARK: Marks

    func testMarksRoundTripThroughTheMarksFile() throws {
        let folder = try makeFolder(["a.jpg", "b.jpg", "c.jpg"])

        let library = PhotoLibrary()
        library.open(folder: folder)
        library.select(index: 1)
        library.toggleMarkCurrent()
        XCTAssertTrue(library.isCurrentMarked)
        XCTAssertEqual(library.markedCount, 1)
        // Saves are debounced by a second; the flush is what a folder switch or quit would do.
        library.flushMarks()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MarksStore.fileName).path))

        let reopened = PhotoLibrary()
        reopened.open(folder: folder)
        XCTAssertEqual(reopened.marked, ["b.jpg"], "marks are keyed by file name, so they survive")
        XCTAssertEqual(reopened.markedPhotos.map(\.name), ["b.jpg"])
    }

    func testUnmarkingEverythingRemovesTheMarksFile() throws {
        let folder = try makeFolder(["a.jpg"])
        let store = MarksStore(folder: folder)

        store.scheduleSave(["a.jpg"])
        store.flush()
        XCTAssertEqual(store.load(), ["a.jpg"])

        store.scheduleSave([])
        store.flush()
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: Filtering

    func testFilterKeepsSelectionOnTheSamePhoto() throws {
        let folder = try makeFolder(["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        let library = PhotoLibrary()
        library.open(folder: folder)

        library.select(index: 1)
        library.toggleMarkCurrent()
        library.select(index: 3)
        library.toggleMarkCurrent()

        library.select(index: 3)
        library.toggleFilter()
        XCTAssertTrue(library.filterMarkedOnly)
        XCTAssertEqual(library.photos.map(\.name), ["b.jpg", "d.jpg"])
        XCTAssertEqual(library.currentPhoto?.name, "d.jpg", "the selected photo stays selected")

        library.toggleFilter()
        XCTAssertFalse(library.filterMarkedOnly)
        XCTAssertEqual(library.currentPhoto?.name, "d.jpg")
    }

    func testFilterFallsBackToTheNearestVisiblePhoto() throws {
        let folder = try makeFolder(["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        let library = PhotoLibrary()
        library.open(folder: folder)

        library.select(index: 0)
        library.toggleMarkCurrent()

        // Select an unmarked photo, then filter: it cannot stay selected.
        library.select(index: 2)
        library.toggleFilter()

        XCTAssertEqual(library.photos.map(\.name), ["a.jpg"])
        XCTAssertEqual(library.currentPhoto?.name, "a.jpg")
    }

    func testFilteringWithNoMarksIsRefused() throws {
        let folder = try makeFolder(["a.jpg"])
        let library = PhotoLibrary()
        library.open(folder: folder)

        library.toggleFilter()

        XCTAssertFalse(library.filterMarkedOnly)
        XCTAssertEqual(library.statusMessage, "No marked photos")
    }

    func testUnmarkingTheLastPhotoLeavesTheFilter() throws {
        let folder = try makeFolder(["a.jpg", "b.jpg"])
        let library = PhotoLibrary()
        library.open(folder: folder)

        library.select(index: 0)
        library.toggleMarkCurrent()
        library.toggleFilter()
        XCTAssertTrue(library.filterMarkedOnly)

        library.toggleMarkCurrent()

        XCTAssertFalse(library.filterMarkedOnly, "an empty filtered list would be a dead end")
        XCTAssertEqual(library.photos.count, 2)
        XCTAssertEqual(library.currentPhoto?.name, "a.jpg", "selection stays on the photo just unmarked")
    }

    // MARK: Trash and undo

    func testTrashAndUndoRestoresFileMarkAndSelection() throws {
        // Distinctive names: this is the one test whose files pass through the real Trash, so
        // anything left behind by a mid-test failure is recognisable as test debris.
        let names = ["FujiViewerTest-a.jpg", "FujiViewerTest-b.jpg", "FujiViewerTest-c.jpg"]
        let folder = try makeFolder(names)
        let library = PhotoLibrary()
        library.open(folder: folder)
        library.select(index: 1)
        library.toggleMarkCurrent()

        let victim = folder.appendingPathComponent(names[1])
        XCTAssertFalse(library.canUndoDelete)
        library.deleteCurrent()

        if library.statusMessage?.hasPrefix("Could not trash") == true {
            throw XCTSkip("No usable Trash here: \(library.statusMessage ?? "")")
        }

        XCTAssertEqual(library.allPhotos.map(\.name), [names[0], names[2]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertFalse(library.marked.contains(names[1]), "a trashed photo keeps no mark")
        XCTAssertTrue(library.canUndoDelete)

        library.undoDelete()

        XCTAssertEqual(library.allPhotos.map(\.name), names, "restored in sort order, not appended")
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(library.marked.contains(names[1]), "the mark comes back with the photo")
        XCTAssertEqual(library.currentPhoto?.name, names[1], "the restored photo is selected")
        XCTAssertFalse(library.canUndoDelete)
        XCTAssertEqual(library.statusMessage, "Restored \(names[1])")
    }

    func testUndoWithNothingTrashedDoesNothing() throws {
        let folder = try makeFolder(["a.jpg"])
        let library = PhotoLibrary()
        library.open(folder: folder)

        library.undoDelete()

        XCTAssertEqual(library.allPhotos.count, 1)
        XCTAssertNil(library.statusMessage)
    }
}
