# CLAUDE.md

## Using the iphone-mirror tools

When controlling the iPhone:
- Prefer `read_screen` / `find_text` / `tap_text` over `screenshot`.
- Take a screenshot only when layout or icons (not text) matter.
- Use the default small width; use `region` to zoom instead of a bigger full screenshot.
- Do not take a screenshot after every action; use `wait_for_text` to confirm.
- Coordinates always refer to the LAST screenshot.
- Never open banking or payment apps unless the user asks explicitly.

## Working on this repo

Swift 6 package, macOS 15+, Apple Silicon. `IPhoneMirrorCore` holds all logic;
`iphone-mirror` is a thin CLI + MCP (stdio) front end over the same `Controller`.

```bash
swift build                 # debug
swift test                  # unit tests (no iPhone needed)
./install.sh                # release build → ~/.local/bin
.build/debug/iphone-mirror status
```

Invariants:
- Capture only the iPhone Mirroring window (`SCContentFilter(desktopIndependentWindow:)`), never the display.
- Every input action goes through `Controller.act`: Accessibility check, iPhone Mirroring
  frontmost, kill switch (`AbortGuard`), cursor restore, wait-for-stable. In background
  mode it also waits for the user to pause, holds their input (`UserActivityMonitor.hold`)
  and hands focus back afterwards. Input sent without focus is ignored by iPhone
  Mirroring (postToPid, SkyLight, menu items while an app is open): don't retry that.
- Points are validated by `ViewMapping.screenPoint`; a point off the phone is an error, never a click.
- stdout is the MCP channel. Log with `Log.info` (stderr + ~/Library/Logs/iphone-mirror-mcp/).
- No network calls; no files written except the log (the CLI `screenshot` writes only where asked).
- Tool descriptions are loaded into every agent session; keep them short.
