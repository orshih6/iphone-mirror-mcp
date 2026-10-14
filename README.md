# iphone-mirror-mcp

Let Claude Code (or any MCP client) see and control a real iPhone through the
macOS **iPhone Mirroring** app. No Xcode, no USB, no jailbreak, no WebDriverAgent.

It is built to spend as few tokens as possible per step:

- **Text first.** `read_screen` returns OCR text with boxes as compact JSON, with no image.
  `tap_text "Settings"` finds and taps text in one call.
- **Small images.** Screenshots are cropped to the phone screen, 320 px wide, JPEG q50
  (usually 10–25 KB). Use `region` to zoom in rather than taking a bigger full screenshot.
- **"unchanged".** If the screen has not changed since the last screenshot, you get the
  word `unchanged` instead of an image.
- **No auto-screenshots.** Actions return `ok`. Each one waits until the screen stops
  changing before it returns, so you don't need an "is it loaded yet?" screenshot.

It ships as one binary that works both as a **CLI** (`iphone-mirror tap-text Settings`)
and as an **MCP server** (`iphone-mirror mcp`).

## Requirements

- macOS 15 (Sequoia) or later, Apple Silicon
- An iPhone set up for [iPhone Mirroring](https://support.apple.com/en-us/120421)
  (iOS 18+, same Apple Account, iPhone locked and nearby)
- Swift 6 toolchain to build (Xcode 16+ or the Command Line Tools)

## Install

```bash
git clone https://github.com/orshih6/iphone-mirror-mcp.git
cd iphone-mirror-mcp
./install.sh                     # builds and installs to ~/.local/bin (override with INSTALL_DIR=…)
claude mcp add --scope user iphone-mirror -- ~/.local/bin/iphone-mirror-mcp
```

### Permissions

macOS grants these permissions to the **app that launches the binary**, not to the binary
itself. That app is your terminal (Terminal, iTerm, Ghostty, …), VS Code, or the Claude app.

| Permission | Why |
|---|---|
| Screen Recording | capture the iPhone Mirroring window (only that window) |
| Accessibility | post mouse and keyboard events, press iPhone Mirroring menu items |

```bash
iphone-mirror permissions   # shows the system prompts for the host app
iphone-mirror status        # tells you exactly which permission is missing, and for which app
```

Enable both under **System Settings › Privacy & Security**, then quit and reopen that app.

## Tools (MCP)

| Tool | Input | Output |
|---|---|---|
| `status` | — | permissions, window, mirroring state |
| `launch` | — | opens/focuses iPhone Mirroring, waits for the phone |
| `screenshot` | `width?` `region?` `gray?` `format?` `force?` | small image, or `unchanged` |
| `read_screen` | `region?` `fast?` | `{"view":[w,h],"items":[[text,cx,cy,w,h,conf],…]}`; cx,cy is the tappable center |
| `find_text` | `text` `exact?` | matches with center points |
| `tap` | `x` `y` `normalized?` | `ok` |
| `tap_text` | `text` `index?` | taps the matched text; error if 0 or several matches |
| `long_press` | `x` `y` `ms?` (800) | `ok` |
| `swipe` | `from{x,y}` `to{x,y}` `ms?` (300) | `ok` |
| `scroll` | `direction` `amount?` | `ok` (scroll-wheel events inside the window) |
| `type_text` | `text` `method?` | `ok (keys \| unicode)` |
| `press_key` | `key` (`return` `delete` `escape` `tab` `space` arrows, `cmd+a`…) | `ok` |
| `home` / `app_switcher` / `spotlight` | — | `ok` |
| `open_app` | `name` | Spotlight → type → return |
| `wait_for_text` | `text` `timeout_ms?` (5000) | polls OCR (no images) until the text appears; `a\|b` waits for either |

Every action also accepts `return_screenshot: true` to get one small image back afterwards,
and `wait: false` to skip waiting for the screen to settle (fewer captures, see below).

### Coordinates

All `x`/`y` values are **pixels in the last screenshot** (top-left origin). Before any
screenshot, they refer to the default view: the full phone at `default_width`.
`read_screen` and `find_text` report positions in that same space, so you can pass them
straight to `tap`. `normalized: true` takes 0..1 fractions instead. A point that falls
outside the phone screen is rejected and nothing is clicked.

`screenshot` with `region: {x,y,w,h}` zooms in. After that, coordinates refer to the
zoomed image until the next full screenshot.

## CLI

```bash
iphone-mirror status
iphone-mirror launch
iphone-mirror screenshot -o phone.jpg          # --width 400 --region 0,0,320,200 --gray --png
iphone-mirror read                             # OCR JSON (accurate); --fast for quick Latin-only
iphone-mirror tap-text Settings
iphone-mirror scroll down
iphone-mirror type "Сайн байна уу"             # non-ASCII goes as Unicode key events
iphone-mirror key return
iphone-mirror home
iphone-mirror open-app Notes
iphone-mirror wait-text "General" --timeout 3000
iphone-mirror run "tap 160 644 --no-wait" "sleep 400" "read"   # several steps, one process
iphone-mirror mcp                              # MCP server on stdio
```

The CLI is stateless, so its coordinates refer to a full-screen screenshot at the same
`--width` (default 320).

## Configuration

Optional: `~/.config/iphone-mirror-mcp/config.json`, or set the `IPHONE_MIRROR_CONFIG`
path. Every key is optional; see [`config.example.json`](config.example.json).

| Key | Default | |
|---|---|---|
| `bundle_id` | `com.apple.ScreenContinuity` | iPhone Mirroring's bundle id |
| `default_width` | `320` | screenshot width, 240–600 |
| `jpeg_quality` | `50` | image tokens depend on pixel size, not bytes; this only affects transfer size |
| `blocked_apps` | `[]` | `open_app` and `tap_text` refuse these names |
| `crop_insets` | `0,0,0,0` | extra trim (points) if your window crop includes chrome |
| `ocr_languages` | `["en-US"]` | add e.g. `"ru-RU"` and use `accurate` for Cyrillic |
| `menu_home` / `menu_app_switcher` / `menu_spotlight` | `Home Screen` / `App Switcher` / `Spotlight` | menu titles to press; falls back to ⌘1 / ⌘2 / ⌘3 |
| `stable_interval_ms` / `stable_timeout_ms` | `150` / `2000` | wait-for-stable tuning |
| `restore_mouse` | `true` | put the cursor back after each action |

An invalid config file is an error rather than being ignored, because it may contain
`blocked_apps`.

## Safety

- Only the iPhone Mirroring window is captured, never the full display.
- Input is sent only while iPhone Mirroring is the frontmost app, and only to points
  inside the phone screen. The frontmost check runs again between every step.
- **Kill switch:** press **Esc** or move/click the mouse during an action and it stops with
  `aborted by user (…)`. A listen-only event tap tells your input apart from the tool's
  (every posted event carries a marker), so iOS pointer snapping cannot trigger it.
- Your cursor position is restored after each action.
- `blocked_apps` keeps `open_app` / `tap_text` away from banking or payment apps.
- No network calls. The only file written is the log at
  `~/Library/Logs/iphone-mirror-mcp/iphone-mirror.log`, which records each image's byte
  size so you can measure token use.

## Things to know

- **Every capture is reported to the iPhone as a screenshot.** Most apps ignore it, but
  some react: Pinduoduo, for example, pops up a "share" sheet after each capture, and
  apps that warn about screenshots will warn. The tool keeps captures to a minimum:
  taps and keys reuse the known window geometry, and `wait: false` (CLI `--no-wait`)
  skips the settle-wait captures after an action. To dismiss such a sheet and act
  before it returns, chain steps: `iphone-mirror run "tap 160 644 --no-wait" "sleep 400" "read"`.
- **Scrolling** uses plain mouse-wheel events. iPhone Mirroring ignores trackpad-style
  (phased) scroll events.
- **`swipe` (click-drag) does not scroll lists** in iPhone Mirroring on iOS 26 (verified),
  so use `scroll` for lists. `swipe` is kept for drag gestures such as moving sliders.
- If the Mac's screen is locked, all input is refused with a clear error.
- `read_screen` uses accurate OCR by default (fast mode garbles icon labels on busy
  wallpapers). For Chinese or Cyrillic, set `"ocr_languages": ["en-US", "zh-Hans", "ru-RU"]`.

## Typing non-English text

`type_text` with the default `method: "auto"`:

- types ASCII with real key codes (`keys`), like a hardware keyboard
- sends everything else (Chinese, Mongolian Cyrillic, emoji…) as Unicode key events
  (`unicode`); verified with Chinese in a real chat on iOS 26

`method: "paste"` exists but **does not work with iPhone Mirroring today**: its
Edit › Paste menu item is disabled, and a synthetic ⌘V reaches the iPhone as a bare "v".

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Screen Recording permission missing … grant it to "X"` | enable it for X, then restart X |
| `iPhone is not being mirrored … Window says "iPhone in Use"` | lock the iPhone; mirroring pauses while it is in use |
| `window is minimized or on another Space` | bring the window back to the current Space |
| screenshot includes window chrome | set `crop_insets` |
| `home` / `spotlight` do nothing | check the View menu titles in iPhone Mirroring and set `menu_*` |

## Development

```bash
swift build && swift test        # unit tests: coordinate mapping, crop, hash, keys, matching, config
```

Manual acceptance checklist (needs a real iPhone):

1. `status` reports the window and its size.
2. `screenshot` is ≤ 30 KB at default settings.
3. Two screenshots with no change in between → the second returns `unchanged`.
4. `read_screen` on the Home Screen lists app names.
5. `tap_text Settings` opens Settings.
6. `scroll down` moves the Settings list.
7. `type_text "Сайн байна уу"` types correctly in Notes.
8. `home` returns to the Home Screen.
9. A tap outside the phone area is refused.
10. Moving the mouse during a long action aborts it.

## License

MIT
