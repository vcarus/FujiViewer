# Development

## Prerequisites

- macOS 14 or later
- Swift 6 toolchain (Xcode 16 or later, or the matching command-line tools)

The package builds in Swift 5 language mode (`.swiftLanguageMode(.v5)` in `Package.swift`).
`CGImage` is immutable and thread safe but not `Sendable`, and the pipeline hands decoded bitmaps
across queues; language mode v5 keeps that free of strict-concurrency friction. Decoded images are
boxed in `DecodedImage`, an `@unchecked Sendable` wrapper, rather than being passed raw.

## Build and run

```bash
swift build          # debug build
swift run            # run unbundled, prints a key→screen timing line per photo
./build-app.sh       # release build + assemble a double-clickable FujiViewer.app
```

`swift run` is the fast development loop. It sets a regular activation policy explicitly, because an
unbundled binary otherwise gets no Dock presence, never becomes key, and receives no keyboard
events.

A folder cannot be passed as a plain command-line argument: AppKit treats a path argument as a
document open, and SwiftUI's `WindowGroup` then never creates its window. Drag a folder onto the
window, press ⌘O, or `open -a FujiViewer.app <folder>`.

## Packaging

`build-app.sh` does the whole assembly:

1. `swift build -c release`
2. copies the binary into `FujiViewer.app/Contents/MacOS/`
3. renders the icon (below) and copies `AppIcon.icns` into `Contents/Resources/`
4. writes `Info.plist` from a heredoc — bundle id, version, `LSMinimumSystemVersion`,
   `NSHighResolutionCapable`, `CFBundleIconFile`
5. ad-hoc codesigns and verifies the bundle

The repository stays source-only: no binaries are committed, and the `.icns` is generated at
packaging time.

## The app icon

`Icon/make-icon.swift` is a standalone `swift` script that draws the icon (a heart sun over
Mt. Fuji) entirely from paths and writes an `AppIcon.iconset` directory:

```bash
swift Icon/make-icon.swift /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o /tmp/AppIcon.icns
```

Because the drawing is resolution-independent, every size (16 → 1024 px) is rendered at its own
resolution rather than resampled from one master bitmap. To change the artwork, edit the drawing
functions (`beginPlate`, `drawFuji`, `fillHeart`) and re-run `./build-app.sh`; sizes and file names
come from the `variants` table and should not need touching.

## Testing with a harness

There is no XCTest target. The pattern used for the pipeline, the exporter and the library is to
compile the real source files together with a throwaway `main.swift`:

```bash
swiftc -swift-version 5 \
  Sources/FujiViewer/Models/PhotoLibrary.swift \
  Sources/FujiViewer/Models/Marks.swift \
  Sources/FujiViewer/Pipeline/ImagePipeline.swift \
  Sources/FujiViewer/Pipeline/DecodedImage.swift \
  /tmp/harness/main.swift -o /tmp/harness/libtest
```

Notes that make this work:

- `FujiViewerApp.swift` carries `@main`, so exclude it and provide a small `enum Log { static func
  line(_:) }` stub in the harness instead.
- Anything driving `DispatchSource` or debounced work (the folder watcher, mark saves) needs
  `RunLoop.main.run()` and step chaining through `DispatchQueue.main.asyncAfter`.
- SwiftUI views can be rasterised offscreen with `ImageRenderer` to eyeball a layout without
  driving the UI.

**Always run harnesses against copies of photos in a scratch directory.** Never point a test that
trashes, restores, renames or writes at a real photo library. Reading a real folder is fine;
writing to one is not.

## Benchmarking

`swift run` logs one line per photo change:

```
[FujiViewer] DSCF3250.HIF  key→screen 1.4 ms  (preview 1920x1280)
```

That number — key press to bitmap on screen — is the metric that matters. When changing anything on
the browsing path:

- Measure before and after, on the same folder, after a warm-up pass.
- **Measure on Intel.** The app targets modest 2018-class hardware, where a native 40MP decode is
  ~1.7 s. Apple Silicon hides regressions that make that machine unusable.
- Check which level is being displayed in the log line. If a plain arrow-key switch ever reports
  `full`, something has broken the core invariant.
- Watch peak memory in Activity Monitor; the caches are sized to stay well under 1 GB.

## Privacy rule for contributions

Nothing committed to this repository may contain absolute paths, usernames, machine names or
personal email addresses — not in source, scripts, comments, docs or test fixtures. Use relative
paths, and keep scratch work outside the repository or in the gitignored `notes/` directory.

Before committing:

```bash
git diff | grep -nE '/(Users|home)/'
```

Local photo folders sitting in the repository root are personal data. They are gitignored, and they
are read-only as far as the tooling is concerned.
