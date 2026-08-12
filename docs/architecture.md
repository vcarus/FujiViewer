# Architecture

FujiViewer exists because one number dominates everything: on a 2018-class Intel i7 (quad-core,
i7-8559U class), decoding a full 40MP Fujifilm HIF frame costs **~1.7 s**. No decoder setting
avoids that — it is the cost of the pixels. Reading the **1920×1280 preview embedded in the same
file** costs **~50 ms**, and a 256px thumbnail ~98 ms.

So the whole design follows from one rule:

> **The browsing path never decodes at native resolution.**

Measured result on that hardware: **1.1–2.9 ms from key press to the new photo on screen**, because
by the time you press the arrow key the next photo is usually already decoded and in memory.

## The four-level decode cache

`Pipeline/ImagePipeline.swift` holds four independent levels. Every level is produced by
`CGImageSourceCreateThumbnailAtIndex`, which returns an *already decoded* bitmap, so the main thread
never pays a decode cost at display time.

| Level | Longest edge | Used for | Queue | Cache |
|---|---|---|---|---|
| `.thumb` | 256 px | grid cells | 4 workers, **LIFO** | 120 MB / 1200 items |
| `.preview` | 1920 px | the instant a photo changes | 4 workers, FIFO | 300 MB / 48 items |
| `.hq` | 2560 px | swapped in behind the preview | 2 workers, FIFO | 160 MB / 12 items |
| `.full` | native | 100% zoom only | 1 worker | only the current photo |

A native 40MP bitmap is ~160 MB, which is why exactly one is ever retained
(`releaseFullImage(keeping:)` drops it as soon as the selection moves or the zoom returns to fit).

**Why `.thumb` is LIFO.** Grid cells request thumbnails as they appear. A fast scroll leaves a
backlog of requests for cells that are already off screen again, and a FIFO queue would make the
cells you are actually looking at wait behind them. Thumb requests are pushed onto a stack drained
by up to four workers, newest first, so the visible row always wins. The other levels stay FIFO —
their ordering is already driven by the prefetcher.

**Display sequence on a photo change.** Show the best cached bitmap ≤ `.hq` immediately (usually
0 ms), request `.preview` (worst case ~50 ms), then swap in `.hq` when it arrives. The canvas
geometry is identical at every level, so a sharper bitmap never moves anything on screen.

## Generation-based prefetch invalidation

`beginNavigation()` bumps a counter once per selection change. Prefetch requests carry the counter
value they were issued under; when a worker picks one up and the counter has moved on, the request
is dropped before it decodes. Requests the user is actually waiting on pass `generation: nil` and
are never dropped.

This is what makes key-repeat survivable: holding the arrow key down queues work for positions you
have already left, and that work evaporates instead of clogging the queues.

The prefetcher warms `.preview` for ±`prefetchRadius` photos (biased toward the direction of
travel) and `.hq` for the current photo plus the next one.

## The ImageIO orientation quirk

ImageIO applies `kCGImageSourceCreateThumbnailWithTransform` **only when it actually resamples**.
On the fast path — handing back a stored embedded preview verbatim — the flag is silently ignored
and the EXIF orientation is not applied. Portrait shots come back sideways. (Quick Look has the
same bug with these files.)

`ImageDecoder` therefore never trusts the flag:

- For 90° orientations on a non-square image, the result is *verifiable* by aspect ratio, so the
  transform is requested and the returned image is checked against the expected orientation.
- Whenever the check fails, or the orientation is not verifiable, the rotation is done explicitly
  by redrawing through a `CGContext`.

Everything downstream — display, histogram, export — can therefore assume pixels are already in
display orientation.

## Zoom geometry

`ZoomableScrollView` (in `Views/LoupeView.swift`) wraps `NSScrollView` and uses native
magnification:

- The document view is laid out **once, at the photo's native size in points** (native pixels ÷
  backing scale).
- Every zoom level — pinch, double click, Space — is `NSScrollView.magnification`, i.e. GPU scaling
  of a bitmap already on screen. No decode happens during a gesture.
- Fit magnification is the lower bound; 100% (one image pixel per device pixel) is the upper bound.
  A small photo is never blown up past 100% to fill the window.

**Escalating to a native decode.** After a zoom settles, the loupe compares the device pixels the
image now occupies against what the 2560 px bitmap holds. Escalation requires *both* that the user
is past fit **and** that the requirement exceeds the `.hq` ceiling by more than 5%. The
`isFitted` half matters: on a Retina screen a large window already "requires" ~3000 px at fit, so
without it every photo switch would trigger a 40MP decode.

**Zoom lock (Z).** Locking carries magnification and position across photo switches, for comparing
the same detail through a burst. Position is stored as an **anchor — the visible centre as a
fraction of the document size** — so it transfers between photos of any dimensions or orientation.

Two details make it stable:

- A photo's real pixel size arrives one update *after* its preview does. While locked, the canvas
  geometry is held rather than briefly laid out at preview size, because a locked magnification is
  relative to the canvas and would otherwise show the wrong zoom for a few milliseconds.
- The anchor is re-read from the live scroll position at the moment of a switch (panning does not
  emit a zoom report, so the stored anchor could be stale).

At a locked 100% every switch does trigger the native decode, with the preview shown first. That is
inherent to the feature, not a defect.

## Histogram

`Pipeline/Histogram.swift` samples the best cached bitmap ≤ `.hq` in one pass: a
nearest-neighbour redraw into a small sRGB buffer of ~1M samples (~75 ms, background queue). The
redraw does two jobs at once — it *picks* source pixels rather than averaging them (averaging would
hide clipping), and it normalises the pixel format, which matters because a Fuji HIF decodes to
**10 bits per component** and cannot simply be read as bytes.

Output is 256 Rec. 709 luma bins plus the percentage of samples with any channel ≥ 254 (highlight
clip) and all channels ≤ 1 (shadow clip). The chart normalises bin heights to the 99th percentile
so one spike — a sky, a black frame — does not flatten the rest of the curve.

## Export

`Models/PhotoExporter.swift` copies or transcodes marked photos, strictly one file at a time
(a native decode is ~160 MB; parallel transcoding would put a multi-GB peak on the machine for no
throughput gain).

Transcoding re-encodes from the pipeline's decode rather than passing the source through with
`CGImageDestinationAddImageFromSource`, because the pipeline's decode is the verified path to
display-oriented pixels. Orientation tags are then reset to 1, since the pixels are already upright.

**10-bit HIF → 8-bit JPEG.** ImageIO's JPEG destination *fails the write outright* — it does not
convert — when handed a 10-bit-per-component bitmap. JPEG export therefore redraws into an 8-bit
buffer first, keeping the photo's own colour space where one can back a context and falling back to
sRGB otherwise. HEIC, TIFF and PNG keep the full 10-bit data and skip this step.

## Marks

`Models/Marks.swift` writes a hidden `.fujiviewer.json` **inside the browsed folder**:

```json
{ "marked": ["DSCF3250.HIF", "DSCF3255.HIF"] }
```

Marks are keyed by **file name, not path**, so copying or backing up the whole folder carries the
marks with it. Saves are debounced by one second and flushed on folder switch and app termination.

## Folder watching

`open(folder:)` starts a `DispatchSource` file-system observer on an `O_EVTONLY` descriptor (which
does not keep a volume busy). Events are debounced 0.5 s, then the folder is rescanned off the main
thread and the result diffed against the current list.

The diff is what keeps it quiet: the app's own trashing, restoring and mark saves all update the
list *before* the event arrives, so the diff is empty and nothing is reported. Only a real change
prunes removed files from the caches and the mark set, remaps the selection to the same file name
(nearest neighbour if it is gone), and shows a status. If the folder itself disappears, the stale
list stays on screen rather than emptying the window.

## Tunable knobs

| Knob | Where | Effect |
|---|---|---|
| `ImageLevel.hq.maxPixelSize` (2560) | `Pipeline/DecodedImage.swift` | The bitmap that serves fit view and moderate zoom. Raising it sharpens deep zoom before escalation but costs decode time and cache bytes on every photo. |
| `1.05` escalation multiplier | `evaluateRequiredResolution` in `Views/LoupeView.swift` | How far past the `.hq` ceiling the zoom must go before a native decode. Raise it (e.g. `2.0`) to make escalation lazier. |
| `ImagePipeline.prefetchRadius` (6) | `Pipeline/ImagePipeline.swift` | How many photos ahead/behind keep a decoded preview ready. Larger absorbs faster key-repeat at the cost of memory. |
| Cache limits (120 / 300 / 160 MB) | `ImagePipeline.init` | Resident set vs. re-decoding when you scroll back. `NSCache` also evicts under system memory pressure. |
| Queue widths (4 / 4 / 2 / 1) | `ImagePipeline` | Decode parallelism per level. Tuned for a 4-core CPU. |
