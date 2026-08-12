import AppKit
import SwiftUI

/// Copies or transcodes the marked photos into a folder of the user's choice.
struct ExportSheet: View {
    let library: PhotoLibrary
    let ui: ViewerState

    @Environment(\.dismiss) private var dismiss

    @State private var exporter = PhotoExporter()
    @State private var format: ExportFormat = .original
    @State private var quality = 0.9
    @State private var includeMetadata = true

    private var photos: [Photo] { library.markedPhotos }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(photos.count == 1 ? "Export 1 marked photo" : "Export \(photos.count) marked photos")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                Picker("Format:", selection: $format) {
                    ForEach(ExportFormat.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(exporter.isRunning)

                if format.usesQuality {
                    HStack(spacing: 10) {
                        Text("Quality")
                            .font(.system(size: 12))
                        Slider(value: $quality, in: 0.5...1.0)
                        Text("\(Int((quality * 100).rounded()))%")
                            .font(.system(size: 12).monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                    .disabled(exporter.isRunning)
                }

                // A byte-for-byte copy always carries its metadata; the choice only exists when
                // transcoding.
                Toggle("Include EXIF metadata", isOn: $includeMetadata)
                    .toggleStyle(.checkbox)
                    .disabled(format == .original || exporter.isRunning)
            }

            if exporter.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(exporter.completed), total: Double(max(exporter.total, 1)))
                    Text("Exporting \(exporter.completed)/\(exporter.total)…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if !exporter.failed.isEmpty {
                Text("Could not export: \(exporter.failed.joined(separator: ", "))")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if exporter.isRunning {
                    Button("Cancel") { exporter.cancel() }
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export…") { chooseDestination() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(photos.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled(exporter.isRunning)
        // Covers the destination panel too: it opens on top of this sheet, which stays up.
        .onAppear { ui.isModalActive = true }
        .onDisappear { ui.isModalActive = false }
    }

    // MARK: Running

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for the exported photos"
        panel.directoryURL = library.folder
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exporter.run(photos: photos, format: format, quality: quality,
                         includeMetadata: includeMetadata, destination: url) {
                finish(destination: url)
            }
        }
    }

    private func finish(destination url: URL) {
        let exported = exporter.completed
        let total = exporter.total
        if exporter.failed.isEmpty && exported == total {
            dismiss()
            library.showStatus(exported == 1
                ? "Exported 1 photo to \(url.lastPathComponent)"
                : "Exported \(exported) photos to \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if exported + exporter.failed.count < total {
            dismiss()
            library.showStatus("Export cancelled — \(exported)/\(total) exported")
        }
        // Anything left over failed: the sheet stays open with the names.
    }
}
