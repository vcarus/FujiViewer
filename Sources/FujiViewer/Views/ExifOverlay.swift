import SwiftUI

/// Shooting parameters, read from metadata only (no pixel decoding).
struct ExifOverlay: View {
    let metadata: PhotoMetadata?
    let level: ImageLevel?
    let zoomPercent: Int?
    let histogram: Histogram?

    var body: some View {
        VStack {
            Spacer()
            HStack {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(24)
                Spacer()
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        if let metadata {
            VStack(alignment: .leading, spacing: 5) {
                if let histogram {
                    HistogramChart(histogram: histogram)
                        .padding(.bottom, 3)
                }
                Text(metadata.fileName)
                    .font(.system(size: 14, weight: .semibold))
                if let exposure = exposureLine {
                    Text(exposure).font(.system(size: 12, weight: .medium).monospacedDigit())
                }
                if let lens = metadata.lens {
                    Text(lens).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let gear = gearLine {
                    Text(gear).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(technicalLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading metadata…").font(.system(size: 12))
            }
        }
    }

    private var exposureLine: String? {
        guard let metadata else { return nil }
        let parts = [metadata.shutter, metadata.aperture, metadata.iso, metadata.focalLength,
                     metadata.exposureBias == "+0.0 EV" ? nil : metadata.exposureBias]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var gearLine: String? {
        guard let metadata else { return nil }
        let parts = [metadata.camera, metadata.captureDate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var technicalLine: String {
        guard let metadata else { return "" }
        var parts: [String] = []
        if metadata.pixelWidth > 0 {
            parts.append("\(metadata.pixelWidth)×\(metadata.pixelHeight)")
        }
        if let size = metadata.fileSize { parts.append(size) }
        if let level { parts.append("displaying \(level.label)") }
        if let zoomPercent { parts.append("\(zoomPercent)% zoom") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Histogram

/// Luma curve with clipping warnings at the ends it applies to.
private struct HistogramChart: View {
    let histogram: Histogram

    /// A clip smaller than this is specular highlights and sensor noise, not a blown photo.
    private static let clippingThreshold = 0.1

    private let chartWidth: CGFloat = 220
    private let chartHeight: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in
                let ceiling = CGFloat(histogram.displayCeiling)
                var curve = Path()
                curve.move(to: CGPoint(x: 0, y: size.height))
                for (index, count) in histogram.bins.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(histogram.bins.count - 1)
                    let level = min(1, CGFloat(count) / ceiling)
                    curve.addLine(to: CGPoint(x: x, y: size.height - level * size.height))
                }
                curve.addLine(to: CGPoint(x: size.width, y: size.height))
                curve.closeSubpath()

                context.fill(curve, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.55), .white.opacity(0.12)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(curve, with: .color(.white.opacity(0.75)), lineWidth: 1)
            }
            .frame(width: chartWidth, height: chartHeight)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))

            clippingLine
        }
    }

    @ViewBuilder
    private var clippingLine: some View {
        let shadows = histogram.shadowClipping
        let highlights = histogram.highlightClipping
        if shadows > HistogramChart.clippingThreshold || highlights > HistogramChart.clippingThreshold {
            HStack(spacing: 0) {
                if shadows > HistogramChart.clippingThreshold {
                    warning(percent: shadows, tint: .blue)
                }
                Spacer(minLength: 8)
                if highlights > HistogramChart.clippingThreshold {
                    warning(percent: highlights, tint: .orange)
                }
            }
            .frame(width: chartWidth)
        }
    }

    private func warning(percent: Double, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text(String(format: "%.1f%%", percent))
                .font(.system(size: 9).monospacedDigit())
        }
        .foregroundStyle(tint)
    }
}
