# TinyRecorder

A free **macro recorder for macOS**. Record any sequence of mouse clicks, drags, scrolls and keystrokes, then replay it on demand. Lives in the Dock and the menu bar.

macOS doesn't ship a built-in macro recorder — TinyRecorder is one. No subscription, no account, no telemetry, no nag.

[**⬇ Download the latest release**](https://github.com/Aaru1801/TinyTask-macOS/releases/latest)

Unzip `TinyRecorder-1.9.0.zip`, drag TinyRecorder into `/Applications`, and launch. The app walks you through permissions on first launch.

## What's in 1.9 — "Quick Run & Live Activity"

- ⚡ **Quick Run** — press **⌘K** for a Spotlight-style command palette with fuzzy macro search, arrow-key navigation, shortcuts, and instant access to recording, import, editing, and settings.
- 📊 **Finder-style Activity Center** — live recording/countdown state plus playback progress, loop and event counts, percentage, and time remaining in one compact control surface.
- 🧊 **Compact native workspace** — a tighter utility-sized library, dimensional hover/press motion, active-card playback rails, refined empty states, and full Reduce Motion support.
- 🟢 **Progress everywhere** — the playing card, menu-bar item, Dock badge, and Activity Center stay synchronized with percentage or continuous-loop status.
- 🛡️ **Safer playback** — TinyRecorder clears its own windows before synthetic input, cancels exposed panels, releases held keys/buttons on every exit path, and stops playback before reopening interactive UI.
- ⚙️ **Faster, safer internals** — non-blocking playback telemetry, coalesced private library saves, hardened imports, bounded loop counts, and owner-only macro files.

## What's in 1.7 — "Design system"

Implemented the Claude Design redesign as a shared design system:
- 🎨 **Signal palette** — events are colored by kind everywhere (key=blue, click=green, scroll=teal, drag=violet, right-click=amber, move=gray), turning every waveform into something you can read at a glance.
- 🔤 **Refined typography & numerics** — italic-serif "tiny" wordmark, monospaced timestamps/counters, tracked small-caps section labels.
- ⌨️ **Chiseled keycaps** (with a glass variant on the HUD) and a **pulsing record dot**.
- 🟥 **Reel-and-smile brand mark** rendered natively.
- 📋 **Library** — brand row + status, full-width record button with the record-hotkey keycap, ⌘F search, restrained accent on cards.
- 🎬 **Recording HUD** — inky Liquid Glass over the live desktop: gradient mono timer, event-track panel with time ruler, a 4-stat grid (clicks/keys/scroll/drag), and Discard/Stop with keycap chords.

## What's in 1.6 — "Liquid Glass"

- 🧊 **Liquid Glass** (macOS 26+) — applied the Apple way: the floating recording HUD and the pre-record countdown are real `NSGlassEffectView` glass that refracts the desktop behind them, and the Record button is tinted prominent glass. The content layer (cards, sidebar, lists) stays opaque per Apple's guidance, so nothing looks muddy. Falls back to standard vibrancy on macOS 13–15.
- 🎨 **Restrained accent** — selected/current cards use a thin accent border + faint tint instead of a heavy colored fill.
- 🔁 **TinyTask + text import** — open `.rec` (TinyTask) and `.txt`/`.trm` macros, convert from the command line (see below).

## What's in 1.3 — "The Library Update"

- 🚀 **Full Dock app** — proper window, top-of-screen menu bar with File / Edit / Macro / Window / Help, real keyboard shortcuts, frame autosaves between launches
- 👋 **Onboarding wizard** — a four-step welcome flow that grants permissions and explains hotkeys before you record your first macro
- ⌨️ **Per-macro hotkeys** — assign any F-key to any macro and trigger it from anywhere, no need to bring the app forward
- ⭐ **Favorites + library filters** — sidebar with All / Favorites / Recent / Most Played / Has Hotkey / per-tag
- 🏷 **Tags** — organize macros across projects
- 🎨 **Custom icons** — pick an SF Symbol for any macro to scan your library at a glance
- 📊 **Stats** — every card shows play count and last-played; sidebar shows total plays & time replayed
- 🔗 **Macro chains** — when one macro finishes, automatically play another
- ⏳ **Pre-record countdown** — a big floating "3 · 2 · 1" overlay so you have time to switch to the right window
- 🔔 **Dock badge** — pulsing red dot while recording, live percentage or ∞ while playing
- 🔊 **Sound feedback** — optional subtle audio cues on record / play / stop (off by default)
- ✏️ **Editor: insert wait** — add a precise pause anywhere in the timeline
- 🎬 **Floating recording HUD** — live timer, event counter, click/key/scroll breakdown, mini live waveform
- 🎛 **Macro editor** — timeline with color-coded events, drag-to-select range, per-event time/X/Y/key inspector, time-stretch, trim before/after, bulk shift, insert wait
- 🔁 **Per-macro repeat** — each macro stores its own loop count: 1× / N× / **∞ continuous**
- ⏩ **Speed control** — playback at 0.5× / 1× / 2× / 4×
- 📤 **Export** — write any macro out as a self-running `.command` script or as `.tinyrec` JSON
- 📥 **Import** — `.tinyrec` files open natively (Finder double-click, drag onto the dock, File → Import)
- 🌗 **Adaptive light + dark** — system materials, vibrancy, hover states, springy animations
- 🔒 **Native** — Carbon hotkeys + `CGEventTap`, no Electron, no kernel extensions

## First launch

The welcome wizard handles this. If you skipped it, macOS asks for two permissions under **System Settings → Privacy & Security**:

1. **Accessibility** — to *post* synthetic events during playback.
2. **Input Monitoring** — to *observe* events during recording.

The popover and main window detect when either is missing and show an "Open Settings" banner.

## Usage

Click the Dock icon (or menu-bar icon) to open the library:

1. Press **Record** in the header (or **F6**, or **⌘R**). A 3-second countdown appears, then a floating HUD takes over.
2. Run through whatever sequence you want to capture.
3. Press **F6** again or click **Stop** in the HUD. The macro auto-saves into the library.
4. Hit any card's **▶ Play** button (or press **F8**) to replay it.
5. Click **✎ Edit** on a card for the timeline editor — scrub, trim, time-stretch, insert waits, edit individual events.

Each card has small chips for hotkey, loop count, favorite ★, and a **⋯** menu for Rename, Tag, Duplicate, Export, Delete. Cmd-click cards to multi-select for bulk operations. Drag a card onto another to reorder.

## Hotkeys

| Action | Default | Notes |
| --- | --- | --- |
| Record / Stop recording | **F6** | toggle |
| Stop everything | **F7** | aborts recording or playback |
| Play current macro | **F8** | uses the macro's own loop count |
| Quick Run | **⌘K** | fuzzy macro and command palette |
| Search library | **⌘F** | focuses the library search field |
| New recording | **⌘R** | from menu / popover |
| Play | **⌘P** | menu shortcut |
| Stop | **⌘.** | menu shortcut |
| Import macro | **⌘O** | from a `.tinyrec` file |
| Export current | **⌘E** | as a `.command` script |
| Settings | **⌘,** | |
| Library window | **⌘0** | bring to front |

Configurable in **Preferences → Hotkeys**. Any saved macro can also have its own per-macro F-key assigned via the card's "⋯ → Assign Hotkey" — that hotkey will play that specific macro from any app.

## File format

`.tinyrec` is plain JSON, importable via Finder double-click, drag-onto-dock, or **File → Import**:

```json
{
  "version": 3,
  "name": "Slack daily standup",
  "createdAt": 766094400,
  "modifiedAt": 766094412,
  "loops": 1,
  "speed": 1.0,
  "icon": "wave.3.right",
  "tags": ["work", "morning"],
  "favorite": false,
  "hotkey": { "keyCode": 97, "name": "F6" },
  "playCount": 12,
  "lastPlayedAt": 766094412,
  "totalRunTime": 134.7,
  "notes": "",
  "chainTo": null,
  "events": [
    { "kind": 5, "time": 0.012, "x": 412.0, "y": 188.0, "keyCode": 0,
      "flags": 256, "mouseButton": 0, "clickCount": 0,
      "scrollDeltaY": 0, "scrollDeltaX": 0 }
  ]
}
```

The library lives at `~/Library/Application Support/TinyRecorder/library.json`.

## Importing & converting (TinyTask + text)

TinyRecorder reads three macro formats — drag any onto the window, double-click in Finder, use **File → Import**, or the command line:

- **`.tinyrec`** — native (full metadata).
- **`.rec`** — **TinyTask** macros (the Windows recorder). TinyRecorder decodes TinyTask's `EVENTMSG` records and translates Windows virtual-key codes to macOS keycodes automatically. Mouse moves/clicks and standard keystrokes convert reliably; mouse-wheel and non-US layouts are best-effort. The importer reports how many records it parsed vs. skipped.
- **`.txt` / `.trm`** — a simple, hand-editable plain-text format ("TRM"). Export any macro to it via the card menu → **Export → As Text…** or **File → Export as Text…** (⇧⌘E), edit it in any editor, and re-import.

### Text macro format (TRM)

One event per line, leading verb, whitespace-separated. `#` comments and blank lines ignored. `@<seconds>` is an absolute timestamp; `WAIT ms` inserts a delay.

```
TINYRECORDER 1
# move, click, type a Cmd+Space, scroll
@0.000  MOVE 640 400
@0.100  DOWN 640 400 L
@0.160  UP 640 400 L
@0.300  FLAGS CMD 0x100000
@0.310  KEYDOWN SPACE +CMD
@0.380  KEYUP SPACE +CMD
@0.390  FLAGS CMD 0x0
@0.500  KEYDOWN A
@0.530  KEYUP A
@0.700  SCROLL -3 0
```

Verbs: `MOVE x y`, `DRAG x y BTN`, `DOWN/UP x y BTN [clicks=N]` (BTN = `L`/`R`/`M`), `SCROLL dy [dx]`, `KEYDOWN/KEYUP <key> [+MODS]`, `FLAGS <key> <maskhex>`, `WAIT ms`. Keys are symbolic names (`A`, `SPACE`, `F1`, `LEFT`, `CMD`…) or `#<keycode>` for anything unnamed.

### Command-line converter

```bash
# Convert a TinyTask file to a TinyRecorder macro (or to text):
TinyRecorder.app/Contents/MacOS/TinyRecorder --convert macro.rec macro.tinyrec
TinyRecorder.app/Contents/MacOS/TinyRecorder --convert macro.rec macro.txt
```

The output format is chosen by the output file's extension (`.tinyrec`/`.json` or `.txt`/`.trm`).

## Development

Build with `./build.sh` — it compiles the SwiftPM package, assembles `TinyRecorder.app`, stamps the build number from git, and ad-hoc signs so Accessibility approval sticks across rebuilds. Sources live in `Sources/TinyRecorder/`.

Requires the macOS 26 SDK (Xcode 26+) to compile the Liquid Glass layer; the app itself runs on macOS 14 or newer, with standard vibrancy on macOS 14–15. The app must **not** be sandboxed — `CGEventTap` recording and `CGEvent` posting require it off.

## Architecture

| File | Responsibility |
| --- | --- |
| `main.swift` | Entry point + CLI playback dispatch |
| `AppDelegate.swift` | Activation policy, top-of-screen menu, window lifecycle |
| `MainWindowController.swift` | Dockable library window |
| `MenuBarController.swift` | Status item, popover, library glue, hotkey registration |
| `MacroLibrary.swift` | Persistent library + filters + statistics |
| `Recorder.swift` | Live capture via `CGEvent.tapCreate(.cgSessionEventTap)` |
| `Player.swift` | Playback via `CGEvent.post`, loops + speed |
| `HotkeyManager.swift` | Global hotkeys via Carbon `RegisterEventHotKey` |
| `RecordingHUD.swift` | Floating HUD shown during recording |
| `CountdownOverlay.swift` | Pre-record 3-2-1 overlay |
| `WelcomeWindow.swift` | Onboarding wizard |
| `MacroEditor.swift` | Timeline + table + inspector editor |
| `PopoverContentView.swift` | Library UI (popover & main window) |
| `ActivityCenterView.swift` | Live recording/countdown/playback progress surface |
| `QuickRunPalette.swift` | ⌘K fuzzy macro and command launcher |
| `SoundController.swift` | Optional audio feedback |
| `VisualEffects.swift` | Materials, hover styles, brand mark, key-cap chip |
| `AppState.swift` | UserDefaults-backed settings + permission watcher |
| `RecordedEvent.swift` | Codable event model |

## Known limits

- **Screen-coordinate based.** Macros replay the exact pixel positions they were recorded at, so resizing or moving target windows between record and play will misfire.
- **Hardened input paths.** A few apps (some banking apps, secure password fields) reject synthesized input. That's by design at the OS layer.
- **Reserved shortcuts.** Globally-reserved system shortcuts like ⌘Space can't be rebound as TinyRecorder hotkeys.

## License

[MIT](LICENSE) — © 2026 Aarav Bhargava.
