import XCTest
@testable import FujiViewer

final class HistogramTests: XCTestCase {

    func testKnownClippingIsMeasuredExactly() throws {
        // 400×400 = 160,000 samples, below the sampling budget, so every pixel is counted and the
        // expected percentages are exact rather than approximate.
        let image = Fixtures.makeClippingImage(side: 400, whitePixels: 40_000, blackPixels: 10_000)
        let histogram = try XCTUnwrap(Histogram.make(from: image))

        XCTAssertEqual(histogram.highlightClipping, 25.0, accuracy: 0.5, "40,000 of 160,000 pixels")
        XCTAssertEqual(histogram.shadowClipping, 6.25, accuracy: 0.5, "10,000 of 160,000 pixels")
    }

    func testBinsCoverEverySampleAndLandWhereExpected() throws {
        let image = Fixtures.makeClippingImage(side: 400, whitePixels: 40_000, blackPixels: 10_000)
        let histogram = try XCTUnwrap(Histogram.make(from: image))

        XCTAssertEqual(histogram.bins.count, 256)
        XCTAssertEqual(histogram.bins.reduce(0, +), 160_000, "every sampled pixel lands in a bin")
        XCTAssertEqual(histogram.bins[255], 40_000, "pure white is the top bin")
        XCTAssertEqual(histogram.bins[0], 10_000, "pure black is the bottom bin")
        // Mid-grey 0.5 in sRGB encodes to ~128.
        XCTAssertEqual(histogram.bins[120...136].reduce(0, +), 110_000, "the rest is mid-grey")
    }

    func testAFlatImageHasNoClipping() throws {
        let image = Fixtures.makeClippingImage(side: 200, whitePixels: 0, blackPixels: 0)
        let histogram = try XCTUnwrap(Histogram.make(from: image))

        XCTAssertEqual(histogram.highlightClipping, 0)
        XCTAssertEqual(histogram.shadowClipping, 0)
    }

    func testLargeImagesAreSampledDownToTheBudget() throws {
        let image = Fixtures.makeImage(width: 3000, height: 2000)
        let histogram = try XCTUnwrap(Histogram.make(from: image, sampleBudget: 100_000))

        let total = histogram.bins.reduce(0, +)
        XCTAssertLessThan(total, 130_000, "a 6MP image must not be counted pixel by pixel")
        XCTAssertGreaterThan(total, 70_000, "but it must still be sampled meaningfully")
    }

    func testDisplayCeilingIgnoresASingleSpike() throws {
        // The gradient spreads its samples over ~120 bins and the red block drops a twenty-fifth of
        // them into one. The clipping fixture would not do: it fills three bins, so the 99th
        // percentile lands on an empty one, displayCeiling falls back to its max(1, …) floor, and
        // every assertion below passes for a `displayCeiling` that just returned 1.
        let image = Fixtures.makeImage(width: 400, height: 400)
        let histogram = try XCTUnwrap(Histogram.make(from: image))
        let peak = try XCTUnwrap(histogram.bins.max())

        XCTAssertEqual(peak, 6_400, "the red block covers a fifth of each side")
        XCTAssertGreaterThan(histogram.displayCeiling, 1, "a real percentile, not the floor")
        XCTAssertLessThan(histogram.displayCeiling, peak / 2, "one spike must not set the scale")
    }

    func testASinglePixelImageIsStillCounted() {
        // A 1×1 image is the smallest thing the sampler can be handed: the scale maths must not
        // divide by zero or round the sample grid away. The zero-dimension guard in `make` cannot
        // be reached from a test — Core Graphics refuses to build a 0×0 `CGImage` at all — so it
        // stays as defensive code, and this test covers the smallest case that does exist.
        let image = Fixtures.makeClippingImage(side: 1, whitePixels: 0, blackPixels: 0)
        let histogram = Histogram.make(from: image)

        XCTAssertNotNil(histogram)
        XCTAssertEqual(histogram?.bins.reduce(0, +), 1)
    }
}
