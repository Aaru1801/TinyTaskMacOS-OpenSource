
# MiniTinyTask for macOS

A tiny, no-frills macro recorder & player inspired by TinyTask, but for macOS. Records your mouse & keyboard globally and plays them back with timing.

## Quick start

1. **Install Python 3** (macOS usually has it; if not, install from python.org or via Homebrew).
2. Open Terminal and run:
   ```bash
   python3 -m pip install pynput
   ```
3. Download `MiniTinyTask_mac.py` (below) and run:
   ```bash
   python3 MiniTinyTask_mac.py
   ```

## macOS permissions (required)

Go to **System Settings → Privacy & Security** and enable the following for **Terminal** (or your Python app):

- **Accessibility**
- **Input Monitoring**

You may need to restart Terminal (or iTerm) after enabling.

## Use

- **F8** — Start/Stop recording
- **F9** — Play the last recording
- **F10** — Save to JSON
- **F11** — Load from JSON
- **ESC** — Stop playback

The small window lets you set:
- **Speed x** — playback speed multiplier (e.g., 2.0 = twice as fast)
- **Loops** — repeat count
- **Jitter px** — optional random offset to click/move positions

## Notes

- Movement events are throttled to keep files small but still smooth.
- Your toggle keys (F8–F11, ESC) are **not** recorded.
- If your function keys control brightness/volume, hold **Fn** while pressing F8/F9/etc.
- Packaging into an app is optional:
  ```bash
  pip install pyinstaller
  pyinstaller --onefile --windowed MiniTinyTask_mac.py
  ```

**Safety**: This app records keys system‑wide. Only run it for legitimate personal automation, and quit it when not in use.
