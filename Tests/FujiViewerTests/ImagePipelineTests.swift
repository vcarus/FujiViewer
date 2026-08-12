import XCTest
@testable import FujiViewer

final class ImagePipelineTests: XCTestCase {
    private let pipeline = ImagePipeline.shared

    override func setUp() {
        super.setUp()
        // The pipeline is a process-wide singleton, so each test starts from an empty cache.
        pipeline.reset()
    }

    override func tearDown() {
        pipeline.reset()
        super.tearDown()
    }

    private func load(_ url: URL, level: ImageLevel) throws -> DecodedImage? {
        let loaded = expectation(description: "decoded \(level.label)")
        var result: DecodedImage?
        pipeline.load(url, level: level, generation: nil) { image in
            result = image
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 20)
        return result
    }

    func testEachLevelDecodesAndCaches() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "photo.jpg", width: 900, height: 600)

        for level in ImageLevel.allCases {
            XCTAssertNil(pipeline.cachedImage(url, level: level), "\(level.label) starts uncached")
            let decoded = try XCTUnwrap(load(url, level: level), "\(level.label) failed to decode")
            XCTAssertEqual(decoded.level, level)
            XCTAssertGreaterThan(decoded.pixelWidth, 0)
            XCTAssertNotNil(pipeline.cachedImage(url, level: level), "\(level.label) was not cached")
        }
    }

    func testThumbIsDownsampledAndFullIsNative() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "photo.jpg", width: 900, height: 600)

        let thumb = try XCTUnwrap(load(url, level: .thumb))
        XCTAssertEqual(max(thumb.pixelWidth, thumb.pixelHeight), ImageLevel.thumb.maxPixelSize)

        let full = try XCTUnwrap(load(url, level: .full))
        XCTAssertEqual(full.pixelWidth, 900)
        XCTAssertEqual(full.pixelHeight, 600)
    }

    func testBestCachedImageRespectsTheLimit() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "photo.jpg", width: 900, height: 600)

        XCTAssertNil(pipeline.bestCachedImage(url))

        _ = try load(url, level: .thumb)
        XCTAssertEqual(pipeline.bestCachedImage(url)?.level, .thumb)

        _ = try load(url, level: .full)
        XCTAssertEqual(pipeline.bestCachedImage(url)?.level, .full, "the best level wins by default")
        XCTAssertEqual(pipeline.bestCachedImage(url, limit: .hq)?.level, .thumb,
                       "a limit must exclude the levels above it")
    }

    func testReleaseFullImageKeepsOnlyTheRequestedPhoto() throws {
        let folder = try Fixtures.makeDirectory(self)
        let first = try Fixtures.writeJPEG(in: folder, named: "a.jpg")
        let second = try Fixtures.writeJPEG(in: folder, named: "b.jpg")

        _ = try load(first, level: .full)
        _ = try load(second, level: .full)
        XCTAssertNil(pipeline.cachedImage(first, level: .full), "only one native bitmap is retained")
        XCTAssertNotNil(pipeline.cachedImage(second, level: .full))

        pipeline.releaseFullImage(keeping: second)
        XCTAssertNotNil(pipeline.cachedImage(second, level: .full))

        pipeline.releaseFullImage(keeping: nil)
        XCTAssertNil(pipeline.cachedImage(second, level: .full))
    }

    func testForgetEmptiesEveryLevel() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "photo.jpg")

        for level in ImageLevel.allCases {
            _ = try load(url, level: level)
        }
        pipeline.forget(url)

        for level in ImageLevel.allCases {
            XCTAssertNil(pipeline.cachedImage(url, level: level), "\(level.label) survived forget()")
        }
        XCTAssertNil(pipeline.bestCachedImage(url))
    }

    func testResetEmptiesEveryLevel() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "photo.jpg")

        _ = try load(url, level: .preview)
        _ = try load(url, level: .full)
        pipeline.reset()

        XCTAssertNil(pipeline.bestCachedImage(url))
    }

    func testMissingFileDeliversNilWithoutCaching() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = folder.appendingPathComponent("nothing-here.jpg")

        XCTAssertNil(try load(url, level: .preview))
        XCTAssertNil(pipeline.cachedImage(url, level: .preview))
    }

    func testStalePrefetchIsDroppedByGeneration() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "photo.jpg")

        let settled = expectation(description: "prefetch resolved")
        var result: DecodedImage?
        let stale = pipeline.beginNavigation()
        // The selection moves on before the worker picks the request up.
        pipeline.beginNavigation()
        pipeline.load(url, level: .hq, generation: stale) { image in
            result = image
            settled.fulfill()
        }
        wait(for: [settled], timeout: 20)

        XCTAssertNil(result, "a prefetch from a superseded generation must be dropped")
        XCTAssertNil(pipeline.cachedImage(url, level: .hq))
    }
}
