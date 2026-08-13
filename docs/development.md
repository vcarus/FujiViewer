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
- The trash test probes `FileManager.trashItem` on a scratch file first and skips itself
  (`XCTSkip`) if the environment has no usable Trash, rather than failing the run. Probe the
  behaviour, never match on a status message: user-facing copy is not a test seam.
- Anything with an escaping completion goes through `Fixtures.CompletionGate`, which closes when
  the wait ends. Work that outlives its timeout would otherwise call `fulfill()` on a finished
  test, and XCTest answers that by taking the whole process down.
- Assert on pixels, not only on dimensions, when the decoder's orientation is involved: six of the
  eight EXIF orientations leave the frame size untouched.

For one-off exploration outside the suite, the source files can also be compiled directly against a
throwaway `main.swift` (exclude `FujiViewerApp.swift`, which carries `@main`, and stub `enum Log`).
SwiftUI views can be rasterised offscreen with `ImageRenderer` to eyeball a layout without driving
the UI.

## Releases

A release is cut by writing the version's notes, then pushing a tag:

```bash
$EDITOR CHANGELOG.md          # add a '## v1.2.0' section at the top
git commit -am "…"
git tag v1.2.0
git push origin main
git push origin v1.2.0
```

The tag must be a version tag (`v1.1.0`, `v1.1.0-rc1`): the workflow triggers on `v[0-9]*`, and
`build-app.sh` rejects anything that is not a version before it reaches `Info.plist`. Both guards
exist because codesign accepts a bundle whose plist does not parse, so a malformed version would
otherwise ship as a published download.

The tag also needs a matching `## v1.2.0` section in `CHANGELOG.md`. That section, and nothing else,
becomes the release body; the workflow extracts it before building and fails the release if it is
missing or empty. Write its paragraphs unwrapped — GitHub turns a single newline in a release body
into a line break, so text wrapped at the width used everywhere else in this repository arrives on
the page as ragged short lines. GitHub's `--generate-notes` only lists merged pull requests, so on a repository
that commits straight to `main` it degrades to a bare compare link — which is how v1.2.0 first
shipped with a page that said nothing about what changed. The guard runs first so that mistake costs
seconds, not a universal build.

`.github/workflows/release.yml` then runs the tests, builds a universal app with the tag's version
stamped into `Info.plist` (`FUJIVIEWER_VERSION`), asserts that the binary really contains both
architectures, zips the bundle with `ditto`, writes a SHA-256 checksum file, and creates the GitHub
Release with that body plus the compare link.

Releases are ad-hoc signed and deliberately **not notarized** — there is no Apple Developer
certificate involved, which is why the README explains the first-launch warning.

`.github/workflows/ci.yml` runs on every push to `main` and every pull request, in two jobs: the
build and test suite, and `./build-app.sh --universal`, which keeps icon rendering, plist assembly,
codesign and the x86_64 slice's compilation from first being exercised at a tag push.

CI does not run the suite as `x86_64`. Hosted macOS runners are all Apple Silicon, the last Intel
image predates the Swift 6 toolchain, and Rosetta is not a stand-in: it translates instructions
while ImageIO and VideoToolbox still take the host's hardware paths, which is precisely where this
app's behaviour differs between machines. **Intel is covered by running `swift test` on an Intel
machine**, which is where the performance numbers in CONTRIBUTING.md have to come from anyway.

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
