A fast, keyboard-driven culling viewer for Fujifilm HIF/HEIC/JPEG photos on macOS. It is built for
one job: getting through a shoot, marking the keepers and exporting them, without ever waiting on a
decode. Arrow keys move, `F` marks, `L` filters to the marked ones, `Space` toggles fit and 100%,
`?` shows every shortcut.

## Install

Download the zip below, unzip it, and drag `FujiViewer.app` wherever you keep apps. The build is
universal, so it runs natively on both Apple Silicon and Intel.

**First launch.** The app is signed ad-hoc and is not notarized, so macOS blocks the first open:

- **macOS 15 (Sequoia) and later** — open it once, dismiss the warning, then go to
  **System Settings ▸ Privacy & Security**, scroll to the message about FujiViewer, and click
  **Open Anyway**.
- **macOS 14 (Sonoma)** — right-click the app and choose **Open**, then confirm.

Either way it is a one-time step. From the command line, the equivalent is:

```bash
xattr -dr com.apple.quarantine /Applications/FujiViewer.app
```

## Verifying the download

`checksums.txt` carries the SHA-256 of the zip:

```bash
shasum -a 256 -c checksums.txt
```

## Requirements

macOS 14 or later. No dependencies, nothing to configure, no library to import into — it reads the
folder you point it at.
