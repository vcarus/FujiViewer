import CoreGraphics
import Foundation
import ImageIO

// MARK: - Decoder

/// All pixel decoding goes through `CGImageSourceCreateThumbnailAtIndex`, which returns an already
/// decoded bitmap so the main thread never pays a decode cost when the image is displayed.
enum ImageDecoder {

    struct SourceInfo {
        var pixelWidth: Int = 0
        var pixelHeight: Int = 0
        /// EXIF orientation, 1...8.
        var orientation: Int = 1

        /// Orientations 5...8 rotate by 90°, which swaps width and height.
        var swapsDimensions: Bool { orientation >= 5 && orientation <= 8 }
        var displayWidth: Int { swapsDimensions ? pixelHeight : pixelWidth }
        var displayHeight: Int { swapsDimensions ? pixelWidth : pixelHeight }
    }

    static func makeSource(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    static func sourceInfo(_ source: CGImageSource) -> SourceInfo {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return SourceInfo()
        }
        return SourceInfo(
            pixelWidth: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
            pixelHeight: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            orientation: props[kCGImagePropertyOrientation] as? Int ?? 1
        )
    }

    /// Display-oriented pixel dimensions, read from metadata only (no pixel decoding).
    static func displayPixelSize(of url: URL) -> CGSize? {
        guard let source = makeSource(url) else { return nil }
        let info = sourceInfo(source)
        guard info.pixelWidth > 0, info.pixelHeight > 0 else { return nil }
        return CGSize(width: info.displayWidth, height: info.displayHeight)
    }

    /// Decodes `url` at `level`. Returns pixels already rotated into display orientation.
    static func decode(url: URL, level: ImageLevel) -> CGImage? {
        guard let source = makeSource(url) else { return nil }
        let info = sourceInfo(source)

        switch level {
        case .thumb:
            let side = ImageLevel.thumb.maxPixelSize
            let embedded = thumbnail(source, maxPixel: side, fromImage: false, ifAbsent: true, transform: false)
            // `IfAbsent` does not synthesise a thumbnail for HEIF at all — a HEIC without an
            // embedded one, which is what this app's own export writes, returns nil — and a few
            // JPEGs only carry a 120px EXIF thumbnail. Resample the real image in both cases.
            var image = embedded
            if embedded == nil || max(embedded?.width ?? 0, embedded?.height ?? 0) < 200 {
                image = thumbnail(source, maxPixel: side, fromImage: true, ifAbsent: true, transform: false) ?? embedded
            }
            return image.flatMap { applyOrientation($0, orientation: info.orientation) }

        case .preview:
            // Fast path: the embedded ~1920px preview, ~40ms on a 40MP HIF.
            let embedded = thumbnail(source, maxPixel: ImageLevel.preview.maxPixelSize,
                                     fromImage: false, ifAbsent: false, transform: false)
            if let embedded, max(embedded.width, embedded.height) >= 800 {
                return applyOrientation(embedded, orientation: info.orientation)
            }
            // No usable embedded preview (plain JPEG): fall back to a real decode, which already
            // returns display-oriented pixels.
            return decodeFromImage(source, info: info, maxPixel: ImageLevel.hq.maxPixelSize)
                ?? embedded.flatMap { applyOrientation($0, orientation: info.orientation) }

        case .hq:
            return decodeFromImage(source, info: info, maxPixel: ImageLevel.hq.maxPixelSize)

        case .full:
            let native = max(info.pixelWidth, info.pixelHeight)
            return decodeFromImage(source, info: info, maxPixel: native > 0 ? native : 8192)
        }
    }

    /// Full decode of the primary image, downsampled to `maxPixel`.
    ///
    /// ImageIO applies `kCGImageSourceCreateThumbnailWithTransform` only when it actually resamples;
    /// when it hands back stored pixels verbatim the orientation is silently ignored. For 90°
    /// orientations the result can be verified by its aspect, so the transform is requested and
    /// checked; otherwise the rotation is done here.
    private static func decodeFromImage(_ source: CGImageSource, info: SourceInfo, maxPixel: Int) -> CGImage? {
        let verifiable = info.swapsDimensions && info.pixelWidth != info.pixelHeight
        guard let image = thumbnail(source, maxPixel: maxPixel, fromImage: true, ifAbsent: true, transform: verifiable) else {
            return nil
        }
        if info.orientation == 1 { return image }
        if verifiable {
            let expectsLandscape = info.displayWidth >= info.displayHeight
            if (image.width >= image.height) == expectsLandscape { return image }
        }
        return applyOrientation(image, orientation: info.orientation)
    }

    private static func thumbnail(_ source: CGImageSource,
                                  maxPixel: Int,
                                  fromImage: Bool,
                                  ifAbsent: Bool,
                                  transform: Bool) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: fromImage,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: ifAbsent,
            kCGImageSourceCreateThumbnailWithTransform: transform,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Rotates/mirrors raw pixels into display orientation.
    static func applyOrientation(_ image: CGImage, orientation: Int) -> CGImage? {
        guard orientation > 1, orientation <= 8 else { return image }
        let width = image.width
        let height = image.height
        let swaps = orientation >= 5
        let outWidth = swaps ? height : width
        let outHeight = swaps ? width : height

        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var context = makeContext(width: outWidth, height: outHeight, colorSpace: image.colorSpace, bitmapInfo: bitmapInfo)
        if context == nil {
            context = makeContext(width: outWidth, height: outHeight,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB), bitmapInfo: bitmapInfo)
        }
        guard let context else { return image }

        context.translateBy(x: CGFloat(outWidth) / 2, y: CGFloat(outHeight) / 2)
        switch orientation {
        case 2: context.scaleBy(x: -1, y: 1)
        case 3: context.rotate(by: .pi)
        case 4: context.scaleBy(x: 1, y: -1)
        case 5: context.rotate(by: -.pi / 2); context.scaleBy(x: -1, y: 1)
        case 6: context.rotate(by: -.pi / 2)
        case 7: context.rotate(by: .pi / 2); context.scaleBy(x: -1, y: 1)
        case 8: context.rotate(by: .pi / 2)
        default: break
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2,
                                       width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage() ?? image
    }

    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?, bitmapInfo: UInt32) -> CGContext? {
        guard let colorSpace, colorSpace.model == .rgb else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: colorSpace, bitmapInfo: bitmapInfo)
    }

    // MARK: Metadata

    /// Reads shooting parameters. Metadata only — no pixels are decoded, so this costs a few ms.
    static func metadata(for url: URL) -> PhotoMetadata {
        var meta = PhotoMetadata(fileName: url.lastPathComponent)
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
            meta.fileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        guard let source = makeSource(url),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return meta
        }
        let info = sourceInfo(source)
        meta.pixelWidth = info.displayWidth
        meta.pixelHeight = info.displayHeight

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = tiff[kCGImagePropertyTIFFMake] as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            meta.camera = [make, model].compactMap { $0 }.joined(separator: " ").trimmed
        }
        guard let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return meta }

        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            meta.shutter = exposure >= 1
                ? String(format: "%.1fs", exposure)
                : "1/\(Int((1 / exposure).rounded()))s"
        }
        if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
            meta.aperture = "f/" + (fNumber < 10 ? String(format: "%.1f", fNumber) : String(format: "%.0f", fNumber))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            meta.iso = "ISO \(iso)"
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            var text = String(format: "%.0fmm", focal)
            if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
                text += " (\(equivalent)mm eq.)"
            }
            meta.focalLength = text
        }
        meta.lens = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmed
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double {
            meta.exposureBias = String(format: "%+.1f EV", bias)
        }
        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            if let date = exifDateParser.date(from: raw) {
                meta.captureDate = exifDateFormatter.string(from: date)
            } else {
                meta.captureDate = raw
            }
        }
        return meta
    }
}

private let exifDateParser: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private let exifDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}()

struct PhotoMetadata: Sendable {
    var fileName: String
    var fileSize: String?
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var shutter: String?
    var aperture: String?
    var iso: String?
    var focalLength: String?
    var lens: String?
    var exposureBias: String?
    var captureDate: String?
    var camera: String?

    var displaySize: CGSize? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Pipeline

/// Four-level decode cache with a prefetcher.
///
/// Browsing never touches a 40MP decode: the selection change is served from the embedded preview
/// (prefetched ±6 around the current photo), a 2560px version is swapped in behind it, and the
/// native-resolution decode only happens for 100% zoom.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private struct InFlight {
        /// The newest generation that asked for this image; `nil` means "must not be dropped".
        var generation: Int?
        var waiters: [(DecodedImage?) -> Void]
    }

    private let thumbCache = NSCache<NSString, DecodedImage>()
    private let previewCache = NSCache<NSString, DecodedImage>()
    private let hqCache = NSCache<NSString, DecodedImage>()

    private let lock = NSLock()
    private var inFlight: [String: InFlight] = [:]
    private var generation = 0
    /// Native-resolution bitmaps are ~160MB each, so only the current one is kept.
    private var fullImage: (key: String, image: DecodedImage)?
    /// Pending thumbnail requests, newest last; drained from the back.
    private var thumbStack: [(url: URL, key: String)] = []
    private var thumbWorkers = 0

    /// Thumbnail queue width, and with it the number of stack-draining workers.
    private static let thumbConcurrency = 4

    private let thumbQueue = ImagePipeline.makeQueue("thumb", concurrency: ImagePipeline.thumbConcurrency, qos: .utility)
    private let previewQueue = ImagePipeline.makeQueue("preview", concurrency: 4, qos: .userInitiated)
    private let hqQueue = ImagePipeline.makeQueue("hq", concurrency: 2, qos: .utility)
    private let fullQueue = ImagePipeline.makeQueue("full", concurrency: 1, qos: .userInitiated)

    /// How many photos ahead/behind keep a decoded preview ready.
    static let prefetchRadius = 6

    private init() {
        thumbCache.totalCostLimit = 120 * 1024 * 1024   // 481 × 256px ≈ 84MB, everything fits
        thumbCache.countLimit = 1200
        // ~30 × 1920px previews: more than twice the ±6 prefetch window, and keeps the resident
        // set clear of 1GB while browsing.
        previewCache.totalCostLimit = 300 * 1024 * 1024
        previewCache.countLimit = 48
        hqCache.totalCostLimit = 160 * 1024 * 1024      // ~9 × 2560px images
        hqCache.countLimit = 12
    }

    private static func makeQueue(_ name: String, concurrency: Int, qos: QualityOfService) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.fujiviewer.decode.\(name)"
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = qos
        return queue
    }

    // MARK: Generations

    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Invalidates queued prefetch work. Call once per selection change, then request the images
    /// the new selection needs.
    @discardableResult
    func beginNavigation() -> Int {
        lock.lock()
        generation += 1
        let value = generation
        lock.unlock()
        return value
    }

    // MARK: Cache access

    func cachedImage(_ url: URL, level: ImageLevel) -> DecodedImage? {
        let key = cacheKey(url, level)
        switch level {
        case .thumb: return thumbCache.object(forKey: key as NSString)
        case .preview: return previewCache.object(forKey: key as NSString)
        case .hq: return hqCache.object(forKey: key as NSString)
        case .full:
            lock.lock()
            defer { lock.unlock() }
            return fullImage?.key == key ? fullImage?.image : nil
        }
    }

    /// Best already-decoded image for `url`, ignoring levels above `limit`.
    func bestCachedImage(_ url: URL, limit: ImageLevel = .full) -> DecodedImage? {
        for level in ImageLevel.allCases.reversed() where level <= limit {
            if let image = cachedImage(url, level: level) { return image }
        }
        return nil
    }

    // MARK: Loading

    /// Requests `url` at `level`.
    ///
    /// Pass `generation: nil` for images the UI is waiting on (they are always decoded); pass the
    /// value returned by `beginNavigation()` for prefetches so they can be dropped when the
    /// selection moves on.
    func load(_ url: URL,
              level: ImageLevel,
              generation requestGeneration: Int?,
              priority: Operation.QueuePriority = .normal,
              completion: ((DecodedImage?) -> Void)? = nil) {
        if let cached = cachedImage(url, level: level) {
            if let completion {
                DispatchQueue.main.async { completion(cached) }
            }
            return
        }

        let key = cacheKey(url, level)
        var shouldEnqueue = false
        lock.lock()
        if var entry = inFlight[key] {
            if requestGeneration == nil {
                entry.generation = nil
            } else if let existing = entry.generation, let requested = requestGeneration, requested > existing {
                entry.generation = requested
            }
            if let completion { entry.waiters.append(completion) }
            inFlight[key] = entry
        } else {
            inFlight[key] = InFlight(generation: requestGeneration, waiters: completion.map { [$0] } ?? [])
            shouldEnqueue = true
        }
        lock.unlock()

        guard shouldEnqueue else { return }
        guard level != .thumb else {
            enqueueThumb(url: url, key: key)
            return
        }
        let operation = BlockOperation { [weak self] in
            self?.performDecode(url: url, level: level, key: key)
        }
        operation.queuePriority = priority
        queue(for: level).addOperation(operation)
    }

    /// Thumbnails are drained newest-first, so the cells scrolling into view beat the backlog a
    /// fast scroll left behind.
    private func enqueueThumb(url: URL, key: String) {
        lock.lock()
        thumbStack.append((url, key))
        let needsWorker = thumbWorkers < ImagePipeline.thumbConcurrency
        if needsWorker { thumbWorkers += 1 }
        lock.unlock()

        guard needsWorker else { return }
        thumbQueue.addOperation { [weak self] in
            self?.drainThumbStack()
        }
    }

    private func drainThumbStack() {
        while true {
            lock.lock()
            guard let request = thumbStack.popLast() else {
                thumbWorkers -= 1
                lock.unlock()
                return
            }
            lock.unlock()
            performDecode(url: request.url, level: .thumb, key: request.key)
        }
    }

    private func performDecode(url: URL, level: ImageLevel, key: String) {
        lock.lock()
        let entry = inFlight[key]
        let isStale: Bool
        if let entryGeneration = entry?.generation {
            isStale = entryGeneration != generation
        } else {
            isStale = false
        }
        if isStale {
            let waiters = entry?.waiters ?? []
            inFlight[key] = nil
            lock.unlock()
            deliver(nil, to: waiters)
            return
        }
        lock.unlock()

        let decoded = ImageDecoder.decode(url: url, level: level).map { DecodedImage(cgImage: $0, level: level) }
        if let decoded { store(decoded, key: key, level: level) }

        lock.lock()
        let waiters = inFlight[key]?.waiters ?? []
        inFlight[key] = nil
        lock.unlock()
        deliver(decoded, to: waiters)
    }

    private func deliver(_ image: DecodedImage?, to waiters: [(DecodedImage?) -> Void]) {
        guard !waiters.isEmpty else { return }
        DispatchQueue.main.async {
            for waiter in waiters { waiter(image) }
        }
    }

    private func store(_ image: DecodedImage, key: String, level: ImageLevel) {
        switch level {
        case .thumb: thumbCache.setObject(image, forKey: key as NSString, cost: image.byteCost)
        case .preview: previewCache.setObject(image, forKey: key as NSString, cost: image.byteCost)
        case .hq: hqCache.setObject(image, forKey: key as NSString, cost: image.byteCost)
        case .full:
            lock.lock()
            fullImage = (key, image)
            lock.unlock()
        }
    }

    private func queue(for level: ImageLevel) -> OperationQueue {
        switch level {
        case .thumb: return thumbQueue
        case .preview: return previewQueue
        case .hq: return hqQueue
        case .full: return fullQueue
        }
    }

    private func cacheKey(_ url: URL, _ level: ImageLevel) -> String {
        "\(level.rawValue)|\(url.path)"
    }

    // MARK: Prefetch

    /// Warms previews around `index` (favouring `direction`) and the 2560px versions of the current
    /// photo and the next one.
    func prefetch(urls: [URL], index: Int, direction: Int, generation prefetchGeneration: Int) {
        guard urls.indices.contains(index) else { return }
        let forward = direction >= 0 ? 1 : -1

        for distance in 1...ImagePipeline.prefetchRadius {
            for offset in [distance * forward, -distance * forward] {
                let neighbour = index + offset
                guard urls.indices.contains(neighbour) else { continue }
                load(urls[neighbour], level: .preview, generation: prefetchGeneration,
                     priority: distance <= 2 ? .high : .normal)
            }
        }

        load(urls[index], level: .hq, generation: prefetchGeneration, priority: .veryHigh)
        let next = index + forward
        if urls.indices.contains(next) {
            load(urls[next], level: .hq, generation: prefetchGeneration, priority: .normal)
        }
    }

    /// Drops everything; used when a different folder is opened.
    func reset() {
        beginNavigation()
        thumbCache.removeAllObjects()
        previewCache.removeAllObjects()
        hqCache.removeAllObjects()
        lock.lock()
        fullImage = nil
        lock.unlock()
    }

    /// Drops the native-resolution bitmap (~160MB) unless it belongs to `url`.
    func releaseFullImage(keeping url: URL?) {
        let keepKey = url.map { cacheKey($0, .full) }
        lock.lock()
        if let current = fullImage, current.key != keepKey {
            fullImage = nil
        }
        lock.unlock()
    }

    /// Forgets a single photo, e.g. after it was moved to the trash.
    func forget(_ url: URL) {
        for level in ImageLevel.allCases {
            let key = cacheKey(url, level)
            switch level {
            case .thumb: thumbCache.removeObject(forKey: key as NSString)
            case .preview: previewCache.removeObject(forKey: key as NSString)
            case .hq: hqCache.removeObject(forKey: key as NSString)
            case .full:
                lock.lock()
                if fullImage?.key == key { fullImage = nil }
                lock.unlock()
            }
        }
    }
}
