import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case original
    case jpeg
    case heic
    case tiff
    case png

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original files (copy)"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .png: return "PNG"
        }
    }

    var usesQuality: Bool {
        self == .jpeg || self == .heic
    }

    /// `nil` means "no transcoding", i.e. copy the file as it is.
    var utType: UTType? {
        switch self {
        case .original: return nil
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .png: return .png
        }
    }

    private var fileExtension: String? {
        switch self {
        case .original: return nil
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .png: return "png"
        }
    }

    func fileName(for source: URL) -> String {
        guard let fileExtension else { return source.lastPathComponent }
        return source.deletingPathExtension().lastPathComponent + "." + fileExtension
    }
}

/// Writes marked photos to a folder chosen by the user, optionally transcoding them.
@Observable
final class PhotoExporter {
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var failed: [String] = []

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var isCancelled = false
    @ObservationIgnored private let queue = DispatchQueue(label: "com.fujiviewer.export", qos: .userInitiated)

    /// Takes effect between files: a decode already in flight runs to completion.
    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func run(photos: [Photo],
             format: ExportFormat,
             quality: Double,
             includeMetadata: Bool,
             destination: URL,
             completion: @escaping () -> Void) {
        guard !isRunning else { return }
        lock.lock()
        isCancelled = false
        lock.unlock()
        isRunning = true
        completed = 0
        total = photos.count
        failed = []

        queue.async { [weak self] in
            guard let self else { return }
            var used: Set<String> = []
            // Strictly one file at a time: a 40MP native decode is ~160MB, and transcoding several
            // in parallel would put a multi-GB peak on the machine for no throughput gain.
            for photo in photos {
                if self.cancelled { break }
                let target = PhotoExporter.uniqueURL(in: destination,
                                                     name: format.fileName(for: photo.url),
                                                     taken: &used)
                let ok = PhotoExporter.export(photo.url, to: target, format: format,
                                              quality: quality, includeMetadata: includeMetadata)
                DispatchQueue.main.async {
                    if ok {
                        self.completed += 1
                    } else {
                        self.failed.append(photo.name)
                    }
                }
            }
            DispatchQueue.main.async {
                self.isRunning = false
                completion()
            }
        }
    }

    // MARK: Files

    /// "Name.jpg", then "Name 2.jpg", "Name 3.jpg", … — `taken` covers names this run already
    /// claimed but has not written yet.
    private static func uniqueURL(in folder: URL, name: String, taken: inout Set<String>) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 1
        while taken.contains(candidate.lowercased())
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            counter += 1
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
        }
        taken.insert(candidate.lowercased())
        return folder.appendingPathComponent(candidate)
    }

    private static func export(_ source: URL, to target: URL, format: ExportFormat,
                               quality: Double, includeMetadata: Bool) -> Bool {
        guard let type = format.utType else {
            do {
                try FileManager.default.copyItem(at: source, to: target)
                return true
            } catch {
                NSLog("[FujiViewer] could not copy \(source.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }

        // The pipeline's decode is the only verified path to display-oriented pixels, so the image
        // is re-encoded from it rather than passed through with CGImageDestinationAddImageFromSource.
        guard let decoded = ImageDecoder.decode(url: source, level: .full) else {
            NSLog("[FujiViewer] could not decode \(source.lastPathComponent)")
            return false
        }

        var image = decoded
        // Fuji HIF files decode to 10 bits per component. A JPEG holds 8, and ImageIO's JPEG
        // destination fails the write outright instead of converting.
        if format == .jpeg, decoded.bitsPerComponent > 8 {
            guard let flattened = eightBitCopy(decoded) else {
                NSLog("[FujiViewer] could not convert \(source.lastPathComponent) to 8 bit")
                return false
            }
            image = flattened
        }

        var properties: [CFString: Any] = [:]
        if includeMetadata, let imageSource = ImageDecoder.makeSource(source) {
            properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
            // The decoded pixels are already upright, so the orientation tags must not rotate them again.
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        if format.usesQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        guard let destination = CGImageDestinationCreateWithURL(target as CFURL,
                                                                type.identifier as CFString, 1, nil) else {
            NSLog("[FujiViewer] could not create \(target.lastPathComponent)")
            return false
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            NSLog("[FujiViewer] could not write \(target.lastPathComponent)")
            return false
        }
        return true
    }

    /// Redraws into an 8-bit bitmap, keeping the photo's own colour space where one can back a
    /// context (an HDR transfer function cannot, hence the sRGB fallback).
    private static func eightBitCopy(_ image: CGImage) -> CGImage? {
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var context = makeContext(width: image.width, height: image.height,
                                  colorSpace: image.colorSpace, bitmapInfo: bitmapInfo)
        if context == nil {
            context = makeContext(width: image.width, height: image.height,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB), bitmapInfo: bitmapInfo)
        }
        guard let context else { return nil }
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?, bitmapInfo: UInt32) -> CGContext? {
        guard let colorSpace, colorSpace.model == .rgb else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: colorSpace, bitmapInfo: bitmapInfo)
    }
}
