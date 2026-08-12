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
swift test           # the XCTest suite (~2s, synthetic fixtures)
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

Two switches:

- `./build-app.sh --universal` builds for `arm64` and `x86_64` together. It is slower, and it is
  what the release workflow uses; plain `./build-app.sh` stays single-arch for local work.
- `FUJIVIEWER_VERSION=1.1.0 ./build-app.sh` stamps that version into `Info.plist`. It defaults to
  `1.0`, and the release workflow passes the tag.

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

## Tests

```bash
swift test
```

XCTest, in `Tests/FujiViewerTests`, covering the decoder's orientation handling, the four-level
cache and its generation invalidation, folder scanning, marks, filtering, trash-and-undo, export
(transcoding, metadata, collision naming) and the histogram. The whole suite runs in about two
seconds.

**Fixtures are synthetic and generated per run** into a temporary directory by `Fixtures.swift`:
gradient images written out as JPEG and HEIC, one landscape HEIC tagged orientation 6 so the
rotation path is exercised, and one image with an exactly known number of clipped pixels. CI has no
photos, and a test must never be pointed at a real photo library — several of them delete, trash and
restore what they are given.

Two things to know when adding tests:

- `ImagePipeline` is a process-wide singleton, so reset it in `setUp`. `PhotoLibrary` can be
  instantiated directly.
- The trash test skips itself (`XCTSkip`) if the environment has no usable Trash, rather than
  failing the run.

For one-off exploration outside the suite, the source files can also be compiled directly against a
throwaway `main.swift` (exclude `FujiViewerApp.swift`, which carries `@main`, and stub `enum Log`).
SwiftUI views can be rasterised offscreen with `ImageRenderer` to eyeball a layout without driving
the UI.

## Releases

A release is cut by pushing a tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

`.github/workflows/release.yml` then runs the tests, builds a universal app with the tag's version
stamped into `Info.plist` (`FUJIVIEWER_VERSION`), asserts that the binary really contains both
architectures, zips the bundle with `ditto`, writes a SHA-256 checksum file, and creates the GitHub
Release with generated notes.

Releases are ad-hoc signed and deliberately **not notarized** — there is no Apple Developer
certificate involved, which is why the README explains the first-launch warning. `.github/workflows/ci.yml`
runs the same build and tests on every push to `main` and every pull request.

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
