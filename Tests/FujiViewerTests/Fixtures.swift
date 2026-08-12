import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Synthetic images, generated per test run into a temporary directory.
///
/// Nothing here reads the machine it runs on: CI has no photos, and a test must never be pointed at
/// a real photo library — several of these tests delete and trash what they are given.
enum Fixtures {

    // MARK: Directories

    static func makeDirectory(_ testCase: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FujiViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    // MARK: Images

    /// A gradient with an off-centre block, so a wrong rotation is detectable by more than size.
    static func makeImage(width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [CGColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1),
                                           CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                                   options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: max(1, width / 5), height: max(1, height / 5)))
        return context.makeImage()!
    }

    /// Mid-grey with exactly `whitePixels` fully clipped white and `blackPixels` fully clipped black,
    /// so the expected clipping percentages are known before the histogram runs.
    static func makeClippingImage(side: Int, whitePixels: Int, blackPixels: Int) -> CGImage {
        let context = makeContext(width: side, height: side)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let whiteSide = Int(Double(whitePixels).squareRoot().rounded())
        let blackSide = Int(Double(blackPixels).squareRoot().rounded())
        precondition(whiteSide * whiteSide == whitePixels, "whitePixels must be a perfect square")
        precondition(blackSide * blackSide == blackPixels, "blackPixels must be a perfect square")

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: whiteSide, height: whiteSide))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: side - blackSide, y: side - blackSide, width: blackSide, height: blackSide))
        return context.makeImage()!
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue)!
    }

    // MARK: Files

    /// Writes `image` as `type`, tagging it with `orientation` (1...8) and optionally a small EXIF
    /// block, the way a camera would.
    @discardableResult
    static func write(_ image: CGImage,
                      to url: URL,
                      type: UTType,
                      orientation: Int = 1,
                      exif: Bool = false) throws -> URL {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if exif {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifFNumber: 4.0,
                kCGImagePropertyExifISOSpeedRatings: [125],
                kCGImagePropertyExifExposureTime: 1.0 / 420.0,
                kCGImagePropertyExifDateTimeOriginal: "2026:04:18 13:08:24",
            ] as [CFString: Any]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "FUJIFILM",
                kCGImagePropertyTIFFModel: "X-T5",
                kCGImagePropertyTIFFOrientation: orientation,
            ] as [CFString: Any]
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                type.identifier as CFString, 1, nil) else {
            throw FixtureError.couldNotCreate(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.couldNotWrite(url.lastPathComponent)
        }
        return url
    }

    /// A landscape frame tagged orientation 6, i.e. one a camera shot in portrait: stored
    /// `width`×`height`, displayed `height`×`width`.
    @discardableResult
    static func writeRotatedHEIC(in folder: URL,
                                 named name: String = "rotated.heic",
                                 width: Int = 400,
                                 height: Int = 300,
                                 exif: Bool = true) throws -> URL {
        try write(makeImage(width: width, height: height),
                  to: folder.appendingPathComponent(name),
                  type: .heic,
                  orientation: 6,
                  exif: exif)
    }

    @discardableResult
    static func writeJPEG(in folder: URL,
                          named name: String,
                          width: Int = 600,
                          height: Int = 400) throws -> URL {
        try write(makeImage(width: width, height: height),
                  to: folder.appendingPathComponent(name),
                  type: .jpeg)
    }

    enum FixtureError: Error {
        case couldNotCreate(String)
        case couldNotWrite(String)
    }
}
