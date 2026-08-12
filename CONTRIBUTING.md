# Contributing

Thanks for taking a look. This is a small, focused app; the bar for changes is that they keep it
fast and keep it simple.

## Setup

macOS 14+, Swift 6 toolchain (Xcode 16+), no dependencies to install.

```bash
swift build
swift run
```

See [docs/development.md](docs/development.md) for packaging, the icon generator, the harness
testing pattern and benchmarking, and [docs/architecture.md](docs/architecture.md) for how the
decode pipeline works before changing anything on the browsing path.

## Code style

- Match the surrounding idiom rather than introducing a new one.
- **Comments state constraints and rationale the code cannot show** — why a value is what it is,
  what breaks without a guard, which API misbehaves. They never narrate what the next line does.
- UI strings are English.
- No new dependencies.

## Pull requests

- `swift build` must be clean — no errors, no new warnings.
- **Performance-sensitive changes need measured numbers, taken on Intel hardware.** A native 40MP
  decode costs ~1.7 s there; browsing must never trigger one. `swift run` logs a key→screen line per
  photo, which is the number to quote before and after.
- **A new keyboard shortcut is three changes, not one**: the key handler, a matching menu item, and
  an entry in `ShortcutsOverlay`. Update the README shortcut table too.
- Keep the working tree free of unrelated churn.

## No personal information

Nothing committed may contain absolute paths, usernames, machine names or personal email addresses —
in source, scripts, comments, docs or fixtures. Keep scratch work outside the repository or in the
gitignored `notes/` directory, and check before you push:

```bash
git diff | grep -nE '/(Users|home)/'
```

If you test against your own photos, point harnesses at copies in a scratch directory — never at a
real library, and never commit image files.
