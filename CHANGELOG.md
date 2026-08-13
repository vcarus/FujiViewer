# Changelog

The section for a version tag becomes that release's notes on GitHub, so a release cannot be cut
without one — see [docs/development.md](docs/development.md#releases). Newest first.

## v1.2.0

**Clear every heart in a folder at once.** **Photo ▸ Clear All Hearts…** starts a folder's culling
over in one confirmed step, instead of unmarking photo by photo or quitting to delete
`.fujiviewer.json` by hand. The confirmation names the folder and how many hearts are about to go.

The marks file is moved to the Trash rather than deleted, so a mis-click is recoverable: put the
file back from the Trash — it is hidden, so press `⌘⇧.` there to see it — and reopen the folder.
Marking photos one at a time is unchanged and still leaves nothing in the Trash.

The item is deliberately menu-only. A bare key for an action that discards a whole culling pass is
a mis-click waiting to happen.
