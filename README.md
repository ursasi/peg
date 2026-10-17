<p align="center">
  <img src="docs/banner.png" alt="Peg — a free screenshot tool for macOS" width="100%">
</p>

<h1 align="center">Peg</h1>

<p align="center">
  A free, open-source screenshot tool for macOS.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-AppKit-orange">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

<p align="center">
  <a href="README.zh-CN.md">中文说明</a>
</p>

Peg sits in the menu bar and does the everyday screenshot work: frame a
region or a window, mark it up, keep it floating, stitch a long page, record a
short GIF. Recent shots hang on a line under the menu bar — a clothesline,
borrowed from the idea in [Tendedero](https://github.com/mrthomaswebb/tendedero).

Built with AppKit only. Free to use and modify, no account, no network, no
analytics, no auto-updater. Screen Recording is the only permission it asks for.

## Features

| | |
|---|---|
| **Frozen-screen snip** | Every display is captured first, so the selection overlay never appears in the output and the magnifier works on real pixels. |
| **Window snapping** | Hover a window and it is outlined; click to take the whole window, drag to pick your own rectangle. |
| **Inline annotation** | 8 tools (rectangle, ellipse, arrow, pen, marker, text, mosaic, blur) drawn straight onto the frozen screen. What you draw is what you get. |
| **Scroll capture** | Manually scroll a region; frames are aligned by row fingerprints and stitched, both downwards and upwards. |
| **GIF recording** | Frame a region, record up to 20 s at 12 fps, stop with the same shortcut. A red frame shows exactly what is being recorded. |
| **Clothesline** | Recent shots hang from a slowly rippling rope with a timestamp under each sheet; hover for a preview, click to copy, drag anywhere, double-click to open. The clothesline idea comes from Tendedero. |
| **Pins** | Any shot floats above other windows, movable and zoomable, with a shadow and outline so it never melts into the wallpaper. Clipboard text pins too, as a dark code card with a line-number gutter and light syntax colouring; drag it as one piece, hold ⌥ to select inside. |
| **History** | `⌃⌥H` browses everything on disk with search, annotate, pin and trash. |
| **Settings** | Save folder, PNG/JPEG + quality, auto-copy, history retention, rounded corners, dock icon, and editable shortcuts. |

## Shortcuts

| Key | Action |
|---|---|
| `⌃⌥X` | Snip and save — release the mouse and it is already copied and written to disk |
| `⌃⌥A` | Snip and annotate — the tool bar appears under the selection |
| `⌃⌥G` | Record a GIF — frame a region, press again to stop |
| `⌃⌥V` | Pin from the clipboard: press once for the newest copy, again for the one before it (images as pictures, text as a card); the newest shot on disk when nothing was copied |
| `⌃⌥H` | Screenshot history |
| `⌃⌥S` | Show / hide the clothesline |

While sniffing a region: `1`–`8` pick a tool, `⌘Z` undoes, `⏎` commits,
`P` pins the selection, `L` starts a scroll capture, `Esc` leaves the tool and
then the snip.

## Install

Peg is not notarized. Build it yourself:

```bash
git clone https://github.com/ursasi/peg.git
cd peg
bash scripts/build-app.sh
cp -R build/Peg.app /Applications/
open -a /Applications/Peg.app
```

The first snip asks for **Screen Recording**. Grant it, then relaunch Peg —
macOS only hands the screen to an app after a restart. The build script signs
with the first code-signing identity it finds so the permission survives
rebuilds.

Requires macOS 14 or newer and a Swift toolchain (Xcode or the Command Line
Tools).

## Project layout

```
Sources/Peg
├── App         entry point, status item, hot keys, permissions, debug logging
├── Capture     screen capture, snip session, selection overlay, window lookup
├── Annotate    annotation model, renderer, canvas, editor
├── Scroll      frame receiver, matcher, stitcher, self tests
├── Record      GIF recorder and HUD/border
├── Shelf       clothesline panel, cards, hover preview
├── Pin         floating pin windows
├── History     history window and retention
├── Settings    preferences window and stored defaults
└── Support     displays, clipboard/storage, rounded corners
Tools
├── Design      the app mark, shared by both generators
├── MakeIcon    renders AppIcon.icns at build time
└── MakeBanner  renders docs/banner.png
```

## Development

```bash
swift build                 # compile
bash scripts/build-app.sh   # build, generate the icon, sign Peg.app
PEG_SELFTEST=1 .build/debug/Peg   # scroll-capture matcher/stitcher tests
PEG_DEMO=shelf|snip|overlay|settings|annotate  # open one UI without a capture
```

`PEG_DEBUG=1` adds a test channel: write a command to `/tmp/peg-cmd`
(`snip`, `record`, `hover:N`, `click:x,y`, …) and read `/tmp/peg-debug.log`.
It exists so automation never has to synthesise system-wide key events.

## Known limitations

- One display per selection; nothing spans screens.
- Scroll capture needs manual scrolling and refuses frames it cannot align
  confidently rather than guessing.
- Annotations cannot be moved after they are drawn.
- Copying a GIF puts a still frame on the clipboard; drag the file for the
  animation.
- macOS 14+ only, and no notarization.

## License

MIT — see [LICENSE](LICENSE).
