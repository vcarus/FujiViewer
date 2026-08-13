import ImageIO
import XCTest
@testable import FujiViewer

final class PhotoExporterTests: XCTestCase {

    private func export(_ photos: [Photo],
                        format: ExportFormat,
                        quality: Double = 0.9,
                        includeMetadata: Bool = true,
                        to destination: URL) throws -> PhotoExporter {
        let exporter = PhotoExporter()
        let finished = expectation(description: "export finished")
        // An export that outlives the timeout must not fulfil an expectation whose test has ended.
        let gate = Fixtures.CompletionGate()
        defer { gate.close() }

        exporter.run(photos: photos, format: format, quality: quality,
                     includeMetadata: includeMetadata, destination: destination) {
            gate.run { finished.fulfill() }
        }
        wait(for: [finished], timeout: 60)
        return exporter
    }

    private func fileSize(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    // MARK: Transcoding

    func testJPEGExportOfARotatedSourceIsUpright() throws {
        let folder = try Fixtures.makeDirectory(self)
        let destination = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300)

        let exporter = try export([Photo(url: source)], format: .jpeg, to: destination)
        XCTAssertEqual(exporter.completed, 1)
        XCTAssertEqual(exporter.failed, [])

        let exported = destination.appendingPathComponent("rotated.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))

        let props = try properties(of: exported)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 300,
                       "the rotation must be baked into the pixels")
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 400)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1,
                       "upright pixels must not carry a rotating orientation tag")
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation] as? Int ?? 1, 1)
    }

    func testIncludeMetadataCarriesExif() throws {
        let folder = try Fixtures.makeDirectory(self)
        let destination = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeRotatedHEIC(in: folder, exif: true)

        _ = try export([Photo(url: source)], format: .jpeg, includeMetadata: true, to: destination)

        let props = try properties(of: destination.appendingPathComponent("rotated.jpg"))
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifFNumber] as? Double, 4.0)
        XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first, 125)
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "X-T5")
    }

    func testExcludeMetadataStripsToStructuralKeys() throws {
        let folder = try Fixtures.makeDirectory(self)
        let destination = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeRotatedHEIC(in: folder, exif: true)

        _ = try export([Photo(url: source)], format: .jpeg, includeMetadata: false, to: destination)

        let exported = destination.appendingPathComponent("rotated.jpg")
        let props = try properties(of: exported)

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifFNumber], "shooting parameters must not survive")
        XCTAssertNil(exif?[kCGImagePropertyExifISOSpeedRatings])
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel], "the camera must not be identifiable")

        // Structural description of the bitmap still has to be there, and still upright.
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 400)
    }

    func testEveryFormatWritesItsOwnExtension() throws {
        let folder = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeJPEG(in: folder, named: "photo.jpg", width: 240, height: 160)

        for (format, expected) in [(ExportFormat.jpeg, "photo.jpg"), (.heic, "photo.heic"),
                                   (.tiff, "photo.tiff"), (.png, "photo.png")] {
            let destination = try Fixtures.makeDirectory(self)
            let exporter = try export([Photo(url: source)], format: format, to: destination)

            XCTAssertEqual(exporter.completed, 1, "\(format.rawValue) export failed")
            XCTAssertEqual(exporter.failed, [])
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(expected).path),
                          "\(format.rawValue) did not produce \(expected)")
        }
    }

    // MARK: Copying

    func testOriginalFormatCopiesByteForByte() throws {
        let folder = try Fixtures.makeDirectory(self)
        let destination = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeRotatedHEIC(in: folder, exif: true)

        _ = try export([Photo(url: source)], format: .original, to: destination)

        let copied = destination.appendingPathComponent("rotated.heic")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
    }

    // MARK: Collisions

    func testCollidingNamesAreNumbered() throws {
        let folder = try Fixtures.makeDirectory(self)
        let destination = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeJPEG(in: folder, named: "photo.jpg", width: 240, height: 160)
        let photo = Photo(url: source)

        let exporter = try export([photo, photo, photo], format: .jpeg, to: destination)

        XCTAssertEqual(exporter.completed, 3)
        let written = try FileManager.default
            .contentsOfDirectory(atPath: destination.path)
            .sorted()
        XCTAssertEqual(written, ["photo 2.jpg", "photo 3.jpg", "photo.jpg"])
    }

    func testASecondRunDoesNotOverwriteTheFirst() throws {
        let folder = try Fixtures.makeDirectory(self)
        let destination = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeJPEG(in: folder, named: "photo.jpg", width: 240, height: 160)

        _ = try export([Photo(url: source)], format: .jpeg, to: destination)
        _ = try export([Photo(url: source)], format: .jpeg, to: destination)

        let written = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(written, ["photo 2.jpg", "photo.jpg"])
    }

    // MARK: Failures

    func testAnUnreadableFileIsReportedAndTheRunContinues() throws {
        let folder = try Fixtures.makeDirectory(self)
        let destination = try Fixtures.makeDirectory(self)
        let good = try Fixtures.writeJPEG(in: folder, named: "good.jpg", width: 240, height: 160)
        let bad = folder.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)

        let exporter = try export([Photo(url: bad), Photo(url: good)], format: .jpeg, to: destination)

        XCTAssertEqual(exporter.failed, ["bad.jpg"])
        XCTAssertEqual(exporter.completed, 1, "the readable photo still exported")
        XCTAssertEqual(exporter.total, 2)
    }

    // MARK: Naming

    func testFileNameSwapsTheExtension() {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("DSCF1234.HIF")
        XCTAssertEqual(ExportFormat.original.fileName(for: source), "DSCF1234.HIF")
        XCTAssertEqual(ExportFormat.jpeg.fileName(for: source), "DSCF1234.jpg")
        XCTAssertEqual(ExportFormat.heic.fileName(for: source), "DSCF1234.heic")
        XCTAssertEqual(ExportFormat.tiff.fileName(for: source), "DSCF1234.tiff")
        XCTAssertEqual(ExportFormat.png.fileName(for: source), "DSCF1234.png")
    }

    func testQualityReachesTheEncoder() throws {
        let folder = try Fixtures.makeDirectory(self)
        let source = try Fixtures.writeJPEG(in: folder, named: "photo.jpg", width: 900, height: 600)
        let low = try Fixtures.makeDirectory(self)
        let high = try Fixtures.makeDirectory(self)

        _ = try export([Photo(url: source)], format: .jpeg, quality: 0.1, to: low)
        _ = try export([Photo(url: source)], format: .jpeg, quality: 1.0, to: high)

        // Without this, every export test runs at the default 0.9 and the slider could stop
        // reaching kCGImageDestinationLossyCompressionQuality without a single failure.
        XCTAssertLessThan(try fileSize(of: low.appendingPathComponent("photo.jpg")),
                          try fileSize(of: high.appendingPathComponent("photo.jpg")),
                          "the quality argument must reach the encoder")
    }

    func testOnlyLossyFormatsUseQuality() {
        XCTAssertTrue(ExportFormat.jpeg.usesQuality)
        XCTAssertTrue(ExportFormat.heic.usesQuality)
        XCTAssertFalse(ExportFormat.png.usesQuality)
        XCTAssertFalse(ExportFormat.tiff.usesQuality)
        XCTAssertFalse(ExportFormat.original.usesQuality)
        XCTAssertNil(ExportFormat.original.utType)
    }
}
