import CoreGraphics
import Foundation

/// Decode levels, ordered from cheapest to most expensive.
enum ImageLevel: Int, Comparable, CaseIterable {
    /// 256px, for the grid.
    case thumb = 0
    /// ~1920px embedded preview, shown the instant the selection changes.
    case preview = 1
    /// 2560px, matches the display, swapped in when it is ready.
    case hq = 2
    /// Native resolution, only decoded for 100% zoom.
    case full = 3

    static func < (lhs: ImageLevel, rhs: ImageLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .thumb: return "thumb"
        case .preview: return "preview"
        case .hq: return "hq"
        case .full: return "full"
        }
    }

    /// Longest edge this level decodes to; `full` means the photo's native size.
    var maxPixelSize: Int {
        switch self {
        case .thumb: return 256
        case .preview: return 1920
        case .hq: return 2560
        case .full: return .max
        }
    }
}

/// Immutable wrapper around a decoded `CGImage`.
///
/// `CGImage` is not `Sendable` even though it is immutable and thread safe once created, so the
/// pipeline hands decoded bitmaps across queues inside this `@unchecked Sendable` box. Pixels are
/// already rotated into display orientation by `ImageDecoder`.
final class DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    let level: ImageLevel
    /// Approximate memory footprint, used as the NSCache cost.
    let byteCost: Int

    init(cgImage: CGImage, level: ImageLevel) {
        self.cgImage = cgImage
        self.level = level
        self.byteCost = max(1, cgImage.bytesPerRow * cgImage.height)
    }

    var pixelWidth: Int { cgImage.width }
    var pixelHeight: Int { cgImage.height }
    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
}
