# FujiViewer

[![CI](https://github.com/vcarus/FujiViewer/actions/workflows/ci.yml/badge.svg)](https://github.com/vcarus/FujiViewer/actions/workflows/ci.yml)

A fast, keyboard-driven culling viewer for Fujifilm HIF/HEIC/JPEG photos on macOS.

## Why

A Fujifilm X-T5 shoots `.HIF` files: a standard HEIC container holding a 40MP, 10-bit frame, around
17 MB each. Finder and Preview decode those frames in full to show them — roughly **1.7 seconds per
photo** on a 2018-class Intel Mac. Culling a burst that way is painful.

Every one of those files also carries an embedded 1920×1280 preview that takes about 50 ms to read.
FujiViewer browses on that preview, prefetches around your position, and quietly swaps in a sharper
2560px version once you settle. Measured key-press to on-screen: **1.1–2.9 ms**. A native-resolution
decode happens only when you actually zoom in far enough to need the pixels.

## Features

- **Loupe and grid** views, arrow keys throughout, black background, no chrome in the way.
- **Heart marks** stored per folder in a hidden `.fujiviewer.json`, keyed by file name so they
  survive copying or backing up the folder.
- **Marked-only filter** to review your picks in place.
- **Zoom lock** — hold magnification *and* position across photo switches, to compare the same
  detail (an eye, a focus point) through a burst.
- **Histogram** with highlight and shadow clipping percentages in the info overlay.
- **Export** marked photos: originals, or transcoded to JPEG/HEIC/TIFF/PNG with quality and EXIF
  options.
- **Undo-able trash** — ⌘Z puts the last photo back, mark included.
- **Live folder watching**: copy a card in or delete files in Finder and the list follows, keeping
  your place.
- **Full menu bar** for every shortcut, plus a `?` cheat sheet.

## Requirements

macOS 14 or later. Building needs a Swift 6 toolchain (Xcode 16+).

## Download

Grab the latest zip from the [releases page](https://github.com/vcarus/FujiViewer/releases), unzip
it, and drag `FujiViewer.app` wherever you keep apps — `/Applications` is fine. The build is a
universal binary, so it runs natively on both Apple Silicon and Intel Macs.

**First launch.** The app is signed ad-hoc, not notarized, so macOS blocks the first open:

- **macOS 15 (Sequoia) and later** — open it once, dismiss the warning, then go to
  **System Settings ▸ Privacy & Security**, scroll to the message about FujiViewer, and click
  **Open Anyway**.
- **macOS 14 (Sonoma)** — right-click the app and choose **Open**, then confirm.

Either way it is a one-time step. If you prefer the command line:

```bash
xattr -d com.apple.quarantine /Applications/FujiViewer.app
```

## Install

Build from source:

```bash
git clone https://github.com/vcarus/FujiViewer.git
cd FujiViewer
./build-app.sh        # produces a double-clickable FujiViewer.app
```

Or run it straight from the package during development:

```bash
swift run
```

## Usage

Drag a folder of photos onto the window, or press ⌘O. Dragging a folder onto the app icon works
too; a single image file opens its folder and selects it.

| Key | Action |
|---|---|
| ← → | Previous / next photo |
| ↑ ↓ | Previous / next row in the grid |
| ⇞ ⇟ | Back / forward 10 photos |
| ↖ ↘ | First / last photo |
| G / ⌘G | Grid view |
| ↩ | Grid → loupe |
| Space | Fit ↔ 100% |
| Double click | Zoom to the click point |
| Pinch | Continuous zoom |
| Drag | Pan while zoomed in |
| Z | Lock zoom & position |
| ⌘0 | Zoom to fit |
| ⌘1 | Actual size (100%) |
| ⎋ | Zoom to fit, unlock |
| F | Toggle heart |
| L | Marked only |
| ⌫ | Move to Trash |
| ⌘Z | Undo move to Trash |
| ⌘E | Export marked photos… |
| I | Info overlay & histogram |
| ⌘C | Copy photo |
| ⌘R | Reveal in Finder |
| ⌘O | Open folder |
| ? | Shortcut list |
| ⎋ | Close the shortcut list |

## FAQ

**Where are my marks stored?** In a hidden `.fujiviewer.json` inside the folder you are browsing,
listing marked file names. Copy or back up the folder and the marks travel with it. Delete the file
and the marks are gone; nothing is stored outside the folder.

**Why does JPEG export convert to 8-bit?** A Fuji HIF decodes to 10 bits per component, and JPEG
cannot hold that. macOS's image writer refuses the file outright rather than converting, so
FujiViewer converts to 8-bit first. HEIC, TIFF and PNG exports keep the full 10-bit data.

**Does it modify my photos?** No. Photos are only ever read. The single destructive action is Move
to Trash, which uses the system Trash and can be undone with ⌘Z. Exports always write new files to
a folder you choose, never in place.

**Which files does it show?** HIF, HEIC, HEIF, JPG and JPEG, sorted the way Finder sorts them.

## Documentation

- [docs/architecture.md](docs/architecture.md) — the decode pipeline, zoom model, and why it is fast
- [docs/development.md](docs/development.md) — building, packaging, testing, benchmarking
- [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT — see [LICENSE](LICENSE).
