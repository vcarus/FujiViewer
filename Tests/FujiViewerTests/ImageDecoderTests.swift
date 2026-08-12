import UniformTypeIdentifiers
import XCTest
@testable import FujiViewer

/// The orientation handling is the part of the decoder most likely to regress silently: ImageIO
/// ignores `kCGImageSourceCreateThumbnailWithTransform` whenever it hands back stored pixels
/// without resampling, so a portrait frame comes back sideways unless the decoder fixes it.
final class ImageDecoderTests: XCTestCase {

    func testRotatedSourceReportsDisplayDimensions() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300)

        let source = try XCTUnwrap(ImageDecoder.makeSource(url))
        let info = ImageDecoder.sourceInfo(source)

        XCTAssertEqual(info.orientation, 6)
        XCTAssertEqual(info.pixelWidth, 400)
        XCTAssertEqual(info.pixelHeight, 300)
        XCTAssertTrue(info.swapsDimensions)
        XCTAssertEqual(info.displayWidth, 300)
        XCTAssertEqual(info.displayHeight, 400)

        XCTAssertEqual(ImageDecoder.displayPixelSize(of: url), CGSize(width: 300, height: 400))
    }

    func testFullDecodeIsDisplayOriented() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300)

        let image = try XCTUnwrap(ImageDecoder.decode(url: url, level: .full))

        XCTAssertEqual(image.width, 300, "stored 400x300 tagged orientation 6 must display portrait")
        XCTAssertEqual(image.height, 400)
    }

    func testPreviewDecodeIsDisplayOriented() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300)

        let image = try XCTUnwrap(ImageDecoder.decode(url: url, level: .preview))

        XCTAssertGreaterThan(image.height, image.width, "preview must be portrait too")
        XCTAssertEqual(Double(image.width) / Double(image.height), 300.0 / 400.0, accuracy: 0.02)
    }

    func testThumbDecodeIsDisplayOriented() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300)

        let image = try XCTUnwrap(ImageDecoder.decode(url: url, level: .thumb))

        XCTAssertGreaterThan(image.height, image.width)
    }

    func testUprightSourceIsUntouched() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "upright.jpg", width: 600, height: 400)

        let image = try XCTUnwrap(ImageDecoder.decode(url: url, level: .full))

        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 400)
    }

    func testMetadataReadsShootingParameters() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300, exif: true)

        let metadata = ImageDecoder.metadata(for: url)

        XCTAssertEqual(metadata.fileName, "rotated.heic")
        XCTAssertEqual(metadata.pixelWidth, 300, "metadata reports display dimensions")
        XCTAssertEqual(metadata.pixelHeight, 400)
        XCTAssertEqual(metadata.aperture, "f/4.0")
        XCTAssertEqual(metadata.iso, "ISO 125")
        XCTAssertEqual(metadata.camera, "FUJIFILM X-T5")
        XCTAssertNotNil(metadata.captureDate)
    }

    func testUnreadableFileDecodesToNil() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = folder.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: url)

        XCTAssertNil(ImageDecoder.decode(url: url, level: .preview))
        XCTAssertNil(ImageDecoder.displayPixelSize(of: url))
    }
}
