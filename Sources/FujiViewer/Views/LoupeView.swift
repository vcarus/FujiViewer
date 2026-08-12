import AppKit
import SwiftUI

/// Full-window single photo view.
///
/// The selection change is served from the prefetched embedded preview, the 2560px version is
/// swapped in when it arrives, and the native-resolution decode only happens once the zoom level
/// actually needs more pixels than the 2560px bitmap holds.
struct LoupeView: View {
    let library: PhotoLibrary
    let ui: ViewerState

    @State private var displayed: Displayed?
    @State private var metadata: PhotoMetadata?
    @State private var isLoadingFull = false
    @State private var loadFailed = false

    private var pipeline: ImagePipeline { .shared }

    private struct Displayed {
        let url: URL
        let image: DecodedImage
    }

    var body: some View {
        ZStack {
            Color.black

            if let displayed {
                ZoomableImageView(photoID: displayed.url,
                                  image: displayed.image,
                                  nativePixelSize: metadata?.displaySize,
                                  command: ui.zoomCommand,
                                  onZoomChanged: handleZoomChanged)
            } else if loadFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44, weight: .thin))
                    Text(library.currentPhoto?.name ?? "")
                        .font(.system(size: 14, weight: .medium))
                    Text("Could not read this file")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }

            if isLoadingFull {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Decoding full resolution…").font(.system(size: 12))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(16)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if library.isCurrentMarked {
                VStack {
                    HStack {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.red)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(18)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if ui.showExif {
                ExifOverlay(metadata: metadata,
                            level: displayed?.image.level,
                            zoomPercent: ui.zoomStatus?.percent)
            }
        }
        .onAppear { refresh() }
        .onChange(of: library.currentPhoto?.url) { _, _ in refresh() }
    }

    // MARK: Loading

    private func refresh() {
        guard let photo = library.currentPhoto else {
            displayed = nil
            metadata = nil
            return
        }
        let url = photo.url
        loadFailed = false
        isLoadingFull = false
        ui.zoomStatus = nil
        // A 40MP bitmap is ~160MB: never keep the previous photo's around.
        pipeline.releaseFullImage(keeping: url)

        // One generation per selection change: queued prefetches for the old position drop out.
        let generation = pipeline.beginNavigation()

        if let cached = pipeline.bestCachedImage(url, limit: .hq) {
            present(cached, for: url)
        } else if displayed?.url != url {
            displayed = nil
        }

        // The image the user is waiting on is never dropped by a later generation.
        pipeline.load(url, level: .preview, generation: nil, priority: .veryHigh) { image in
            guard library.currentPhoto?.url == url else { return }
            if let image {
                present(image, for: url)
            } else if displayed?.url != url {
                // Corrupt file, or deleted behind our back: placeholder instead of a crash.
                loadFailed = true
                _ = library.consumeNavigationStart()
            }
        }
        pipeline.load(url, level: .hq, generation: generation, priority: .veryHigh) { image in
            guard let image, library.currentPhoto?.url == url else { return }
            present(image, for: url)
        }
        pipeline.prefetch(urls: library.photos.map(\.url),
                          index: library.currentIndex,
                          direction: library.lastDirection,
                          generation: generation)

        loadMetadata(for: url)
    }

    private func present(_ image: DecodedImage, for url: URL) {
        guard library.currentPhoto?.url == url else { return }
        if let current = displayed, current.url == url, current.image.level >= image.level { return }
        displayed = Displayed(url: url, image: image)
        loadFailed = false
        if image.level == .full { isLoadingFull = false }

        if let start = library.consumeNavigationStart() {
            let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Log.line(String(format: "[FujiViewer] %@  key→screen %.1f ms  (%@ %dx%d)",
                            url.lastPathComponent, milliseconds, image.level.label,
                            image.pixelWidth, image.pixelHeight))
        }
    }

    // MARK: Zoom

    /// Reported after a pinch ends, after an animated zoom, and on window resize — never during a
    /// live magnification, so a gesture is pure GPU scaling of the bitmap already on screen.
    private func handleZoomChanged(_ status: ZoomStatus) {
        ui.zoomStatus = status
        evaluateRequiredResolution(for: status)
    }

    private func evaluateRequiredResolution(for status: ZoomStatus) {
        guard let displayed, let native = metadata?.displaySize else { return }

        // Device pixels the image occupies on screen at this magnification.
        let requiredPixels = max(native.width, native.height) * status.magnification
        let hqCeiling = CGFloat(ImageLevel.hq.maxPixelSize)

        if requiredPixels > hqCeiling * 1.05 {
            requestFull(for: displayed.url)
        } else if displayed.image.level == .full {
            releaseFull(for: displayed.url)
        }
    }

    private func requestFull(for url: URL) {
        guard displayed?.image.level != .full else { return }
        if pipeline.cachedImage(url, level: .full) == nil {
            isLoadingFull = true
        }
        pipeline.load(url, level: .full, generation: nil, priority: .veryHigh) { image in
            guard library.currentPhoto?.url == url else { return }
            isLoadingFull = false
            if let image { present(image, for: url) }
        }
    }

    /// Back within what the 2560px bitmap can show: drop the 40MP one again.
    private func releaseFull(for url: URL) {
        isLoadingFull = false
        guard let fallback = pipeline.bestCachedImage(url, limit: .hq) else { return }
        displayed = Displayed(url: url, image: fallback)
        pipeline.releaseFullImage(keeping: nil)
    }

    private func loadMetadata(for url: URL) {
        metadata = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let meta = ImageDecoder.metadata(for: url)
            DispatchQueue.main.async {
                guard library.currentPhoto?.url == url else { return }
                metadata = meta
                // The native size sets the canvas geometry; if the user already zoomed in before
                // it arrived, re-check whether the 40MP decode is needed.
                if let status = ui.zoomStatus {
                    evaluateRequiredResolution(for: status)
                }
            }
        }
    }
}

// MARK: - Zoom plumbing

/// One-shot zoom request sent from the key handler into the AppKit view.
struct ZoomCommand: Equatable {
    enum Kind {
        case none
        case toggle
        case fit
    }

    var kind: Kind = .none
    var token: Int = 0
}

struct ZoomStatus: Equatable {
    var magnification: CGFloat = 1
    /// Magnification at which the whole photo fits the window.
    var fitMagnification: CGFloat = 1

    var isFitted: Bool { magnification <= fitMagnification * 1.02 }
    var percent: Int { Int((magnification * 100).rounded()) }
}

// MARK: - Zoomable image

/// `NSScrollView` with native magnification: the document view is laid out once at the photo's
/// native size and every zoom level — pinch, double click, Space — is `NSScrollView.magnification`,
/// i.e. GPU scaling of the decoded bitmap.
struct ZoomableImageView: NSViewRepresentable {
    let photoID: URL
    let image: DecodedImage
    let nativePixelSize: CGSize?
    let command: ZoomCommand
    let onZoomChanged: (ZoomStatus) -> Void

    func makeNSView(context: Context) -> ZoomableScrollView {
        let view = ZoomableScrollView()
        view.onZoomChanged = onZoomChanged
        context.coordinator.lastCommandToken = command.token
        view.update(photoID: photoID, image: image, nativePixelSize: nativePixelSize)
        return view
    }

    func updateNSView(_ nsView: ZoomableScrollView, context: Context) {
        nsView.onZoomChanged = onZoomChanged
        nsView.update(photoID: photoID, image: image, nativePixelSize: nativePixelSize)

        guard command.token != context.coordinator.lastCommandToken else { return }
        context.coordinator.lastCommandToken = command.token
        switch command.kind {
        case .toggle: nsView.toggleZoom()
        case .fit: nsView.zoomToFit(animated: true)
        case .none: break
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastCommandToken = 0
    }
}

final class ZoomableScrollView: NSScrollView {
    private let canvas = ImageCanvasView()
    private var photoID: URL?
    private var decoded: DecodedImage?
    private var nativePixelSize: CGSize?
    private var fitMagnification: CGFloat = 1
    private var lastReported: ZoomStatus?
    private var isAdjustingLayout = false

    var onZoomChanged: ((ZoomStatus) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        drawsBackground = true
        backgroundColor = .black
        borderType = .noBorder
        // Scrollers would retile the view on every magnification change; panning is by drag and
        // by two-finger scroll, both of which work without them.
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        allowsMagnification = true
        minMagnification = 0.01
        maxMagnification = 1.0

        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        contentView = clipView
        documentView = canvas

        canvas.onDoubleClick = { [weak self] point in
            self?.toggleZoom(centeredAt: point)
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(liveMagnificationEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification,
                                               object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Content

    func update(photoID newPhotoID: URL, image: DecodedImage, nativePixelSize size: CGSize?) {
        let photoChanged = photoID != newPhotoID
        let imageChanged = decoded !== image
        let sizeChanged = nativePixelSize != size
        photoID = newPhotoID
        decoded = image
        nativePixelSize = size

        if imageChanged {
            // Same canvas geometry for every level, so swapping in a sharper bitmap never moves
            // anything on screen.
            canvas.image = image.cgImage
        }
        if photoChanged || imageChanged || sizeChanged {
            applyCanvasGeometry(resetToFit: photoChanged)
        }
    }

    /// The document view is always the photo at its native size in points; magnification does the
    /// rest.
    private func applyCanvasGeometry(resetToFit: Bool) {
        guard let decoded else { return }
        let backingScale = window?.backingScaleFactor ?? 2
        let pixelSize = nativePixelSize ?? decoded.pixelSize
        let size = CGSize(width: max(1, (pixelSize.width / backingScale).rounded()),
                          height: max(1, (pixelSize.height / backingScale).rounded()))

        let wasFitted = isFitted
        if canvas.frame.size != size {
            canvas.frame = CGRect(origin: .zero, size: size)
            canvas.imageFrame = CGRect(origin: .zero, size: size)
        }
        updateMagnificationLimits()
        if resetToFit || wasFitted {
            applyMagnification(fitMagnification, animated: false, centeredAt: nil)
        }
        reportZoom()
    }

    // MARK: Magnification

    private var isFitted: Bool {
        magnification <= fitMagnification * 1.02
    }

    /// Fit is the lower bound, 100% (one image pixel per device pixel) the upper bound.
    private func updateMagnificationLimits() {
        // contentView.frame is the viewport in points; its bounds would already be divided by the
        // current magnification.
        let viewport = contentView.frame.size
        guard viewport.width > 1, viewport.height > 1,
              canvas.frame.width > 1, canvas.frame.height > 1 else { return }

        let rawFit = min(viewport.width / canvas.frame.width, viewport.height / canvas.frame.height)
        // Never blow a small photo up past 100% just to fill the window.
        fitMagnification = min(max(rawFit, 0.01), 1.0)
        minMagnification = fitMagnification
        maxMagnification = max(1.0, fitMagnification)
        if magnification < minMagnification {
            magnification = minMagnification
        }
    }

    override func layout() {
        super.layout()
        guard !isAdjustingLayout else { return }
        isAdjustingLayout = true
        let wasFitted = isFitted
        updateMagnificationLimits()
        if wasFitted {
            applyMagnification(fitMagnification, animated: false, centeredAt: nil)
        }
        isAdjustingLayout = false
        reportZoom()
    }

    func toggleZoom(centeredAt point: NSPoint? = nil) {
        applyMagnification(isFitted ? maxMagnification : fitMagnification,
                           animated: true,
                           centeredAt: point)
    }

    func zoomToFit(animated: Bool) {
        applyMagnification(fitMagnification, animated: animated, centeredAt: nil)
    }

    private func applyMagnification(_ value: CGFloat, animated: Bool, centeredAt point: NSPoint?) {
        let target = min(max(value, minMagnification), maxMagnification)
        let center = point ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        guard animated else {
            setMagnification(target, centeredAt: center)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setMagnification(target, centeredAt: center)
        }, completionHandler: { [weak self] in
            self?.reportZoom()
        })
    }

    @objc private func liveMagnificationEnded(_ notification: Notification) {
        reportZoom()
    }

    private func reportZoom() {
        let status = ZoomStatus(magnification: magnification, fitMagnification: fitMagnification)
        guard status != lastReported else { return }
        lastReported = status
        guard let onZoomChanged else { return }
        // Never mutate SwiftUI state inside a layout pass.
        DispatchQueue.main.async { onZoomChanged(status) }
    }
}

/// Keeps the photo centred whenever it is smaller than the viewport — which is the normal case at
/// fit magnification, where only one axis fills the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if rect.height > documentView.frame.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}

final class ImageCanvasView: NSView {
    private let imageLayer = CALayer()
    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint = .zero

    /// Called with the click location in this view's coordinate space.
    var onDoubleClick: ((NSPoint) -> Void)?

    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = image
            CATransaction.commit()
        }
    }

    var imageFrame: CGRect = .zero {
        didSet {
            guard imageFrame != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = imageFrame
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.allowsEdgeAntialiasing = false
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = scale
        layer?.contentsScale = scale
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        dragStartLocation = event.locationInWindow
        dragStartOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartLocation, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        // Clip bounds are in document units, so window-space deltas scale by the magnification.
        let magnification = max(scrollView.magnification, 0.0001)
        let deltaX = (event.locationInWindow.x - start.x) / magnification
        let deltaY = (event.locationInWindow.y - start.y) / magnification

        let maxX = bounds.width - clip.bounds.width
        let maxY = bounds.height - clip.bounds.height
        guard maxX > 0 || maxY > 0 else { return }

        var origin = clip.bounds.origin
        if maxX > 0 {
            origin.x = min(max(dragStartOrigin.x - deltaX, 0), maxX)
        }
        if maxY > 0 {
            origin.y = min(max(dragStartOrigin.y - deltaY, 0), maxY)
        }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
    }

    override func resetCursorRects() {
        guard let clip = enclosingScrollView?.contentView else { return }
        if clip.bounds.width < bounds.width || clip.bounds.height < bounds.height {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
