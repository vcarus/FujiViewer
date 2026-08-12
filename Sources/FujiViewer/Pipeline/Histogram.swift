import CoreGraphics
import Foundation

/// Luma distribution and clipping of a decoded bitmap.
struct Histogram: Equatable {
    /// 256 luma bins.
    let bins: [Int]
    /// Percent of sampled pixels with any channel at 254 or above.
    let highlightClipping: Double
    /// Percent of sampled pixels with every channel at 1 or below.
    let shadowClipping: Double

    /// Bin count that maps to the top of the chart. The 99th percentile keeps one spike — a sky, a
    /// black frame — from flattening the rest of the curve.
    var displayCeiling: Int {
        let sorted = bins.sorted()
        return max(1, sorted[Int(Double(sorted.count - 1) * 0.99)])
    }

    /// Samples `image` in one pass.
    ///
    /// The sampling is a nearest-neighbour redraw into a small sRGB buffer: it picks source pixels
    /// instead of averaging them (averaging would hide clipping), and it normalises the pixel
    /// format on the way — a Fuji HIF decodes to 10 bits per component, which cannot be read as
    /// bytes.
    static func make(from image: CGImage, sampleBudget: Int = 1_000_000) -> Histogram? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let scale = min(1, (Double(sampleBudget) / Double(width * height)).squareRoot())
        let sampleWidth = max(1, Int((Double(width) * scale).rounded()))
        let sampleHeight = max(1, Int((Double(height) * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: sampleWidth,
                                      height: sampleHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: sampleWidth * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var bins = [Int](repeating: 0, count: 256)
        var highlights = 0
        var shadows = 0
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let sampleCount = sampleWidth * sampleHeight

        for index in 0..<sampleCount {
            let offset = index * 4
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            // Rec. 709 luma. Rounded, not truncated: the weights do not sum to exactly 1 in binary
            // floating point, so pure white computes as 254.999… and would never reach the top bin.
            let luma = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
            bins[min(255, max(0, Int(luma.rounded())))] += 1
            if red >= 254 || green >= 254 || blue >= 254 { highlights += 1 }
            if red <= 1 && green <= 1 && blue <= 1 { shadows += 1 }
        }

        let total = Double(max(sampleCount, 1))
        return Histogram(bins: bins,
                         highlightClipping: Double(highlights) / total * 100,
                         shadowClipping: Double(shadows) / total * 100)
    }
}
