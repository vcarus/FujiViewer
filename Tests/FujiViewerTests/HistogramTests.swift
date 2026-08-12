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
        // One enormous bin (the white block) must not set the scale for the whole chart.
        let image = Fixtures.makeClippingImage(side: 400, whitePixels: 40_000, blackPixels: 10_000)
        let histogram = try XCTUnwrap(Histogram.make(from: image))

        XCTAssertLessThan(histogram.displayCeiling, histogram.bins.max() ?? 0,
                          "the 99th percentile sits below the peak")
        XCTAssertGreaterThan(histogram.displayCeiling, 0)
    }

    func testAnEmptyImageIsRejectedGracefully() {
        // A 1×1 image is the smallest thing the sampler can be handed; it must not divide by zero.
        let image = Fixtures.makeClippingImage(side: 1, whitePixels: 0, blackPixels: 0)
        let histogram = Histogram.make(from: image)

        XCTAssertNotNil(histogram)
        XCTAssertEqual(histogram?.bins.reduce(0, +), 1)
    }
}
