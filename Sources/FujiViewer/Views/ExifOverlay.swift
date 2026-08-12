import SwiftUI

/// Shooting parameters, read from metadata only (no pixel decoding).
struct ExifOverlay: View {
    let metadata: PhotoMetadata?
    let level: ImageLevel?
    let zoomPercent: Int?

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
