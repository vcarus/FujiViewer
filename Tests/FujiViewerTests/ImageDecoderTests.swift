import UniformTypeIdentifiers
import XCTest
@testable import FujiViewer

/// The orientation handling is the part of the decoder most likely to regress silently: ImageIO
/// ignores `kCGImageSourceCreateThumbnailWithTransform` whenever it hands back stored pixels
/// without resampling, so a portrait frame comes back sideways unless the decoder fixes it.
final class ImageDecoderTests: XCTestCase {

    private enum Corner: String {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private typealias Sample = (corner: Corner, color: (red: Int, green: Int, blue: Int))

    /// Asserts that the fixture's red block sits in `corner` of a decoded frame.
    ///
    /// `Fixtures.makeImage` fills a fifth of each side at the stored bottom-left, so sampling at a
    /// tenth in from each edge lands inside the block or well clear of it. This is the only check
    /// that can tell a correct rotation from one 180° out or mirrored: those keep the frame's
    /// dimensions, and dimensions are all the other assertions have to go on.
    ///
    /// The block is found by comparing how red each corner is, rather than against fixed values:
    /// the HEIC fixtures make a lossy HEVC round trip whose colour fidelity depends on the encoder
    /// the machine has. The margin has room to spare — the gradient's warmest corner scores around
    /// 50 against the block's 255 — and a failure prints all four samples, because a fixture whose
    /// pixels did not survive the round trip looks exactly like a rotation bug otherwise.
    private func assertRedBlock(_ image: CGImage, at expected: Corner, _ note: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        let left = max(1, image.width / 10)
        let top = max(1, image.height / 10)
        let points: [(corner: Corner, x: Int, y: Int)] = [
            (.topLeft, left, top),
            (.topRight, image.width - 1 - left, top),
            (.bottomLeft, left, image.height - 1 - top),
            (.bottomRight, image.width - 1 - left, image.height - 1 - top),
        ]
        let samples: [Sample] = points.map { ($0.corner, Fixtures.pixel(image, x: $0.x, y: $0.y)) }

        let ranked = samples.sorted { redness($0.color) > redness($1.color) }
        let readout = samples.map { "\($0.corner)=\($0.color)" }.joined(separator: " ")
        guard let first = ranked.first, let runnerUp = ranked.dropFirst().first,
              redness(first.color) - redness(runnerUp.color) >= 60 else {
            XCTFail("no corner is clearly the reddest. \(note) corners: \(readout)", file: file, line: line)
            return
        }
        XCTAssertEqual(first.corner, expected, "\(note) corners: \(readout)", file: file, line: line)
    }

    private func redness(_ color: (red: Int, green: Int, blue: Int)) -> Int {
        color.red - max(color.green, color.blue)
    }

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
        assertRedBlock(image, at: .topLeft,
                       "orientation 6 turns the stored bottom-left block to the display top-left; "
                       + "180° would put it bottom-right, a mirror top-right, both at 300x400.")
    }

    func testPreviewDecodeIsDisplayOriented() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300)

        let image = try XCTUnwrap(ImageDecoder.decode(url: url, level: .preview))

        XCTAssertGreaterThan(image.height, image.width, "preview must be portrait too")
        XCTAssertEqual(Double(image.width) / Double(image.height), 300.0 / 400.0, accuracy: 0.02)
        assertRedBlock(image, at: .topLeft)
    }

    func testThumbDecodeIsDisplayOriented() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeRotatedHEIC(in: folder, width: 400, height: 300)

        let image = try XCTUnwrap(ImageDecoder.decode(url: url, level: .thumb))

        XCTAssertGreaterThan(image.height, image.width)
        // The HEIC carries no embedded thumbnail, so this is also the resample fallback's own test.
        assertRedBlock(image, at: .topLeft)
    }

    func testUprightSourceIsUntouched() throws {
        let folder = try Fixtures.makeDirectory(self)
        let url = try Fixtures.writeJPEG(in: folder, named: "upright.jpg", width: 600, height: 400)

        let image = try XCTUnwrap(ImageDecoder.decode(url: url, level: .full))

        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 400)
        assertRedBlock(image, at: .bottomLeft, "an untagged frame must come back exactly as stored.")
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
