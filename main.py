# SPDX-License-Identifier: GPL-3.0-or-later
import threading
import time
from pynput import keyboard
from models import Macro
from recorder import Recorder
from player import Player
from ui import AppUI

# ---- Globals wired together ---------------------------------------------------

rec = Recorder(move_min_interval=0.01)  # configurable
rec.attach()

player = Player()
macro_ref = Macro(events=[])

def set_status(msg: str):
    ui.set_status(msg)

# ---- Control-key filtering so recorder doesn't capture our hotkeys ---------

# Map "F1".."F19" to pynput Key objects
_FKEY_TO_PYNPUT = {f"F{i}": getattr(keyboard.Key, f"f{i}") for i in range(1, 20)}

# Small time window to ignore key events right after we trigger an action
_ignore_until = 0.0

def squelch(ms: int = 180):
    """Ignore key events for a brief window (to drop the triggering F-key)."""
    global _ignore_until
    _ignore_until = time.time() + (ms / 1000.0)

def get_control_keys():
    """Return a set of pynput Key objects for the UI's current F-key bindings."""
    try:
        return {
            _FKEY_TO_PYNPUT.get(ui.keys["record"]),
            _FKEY_TO_PYNPUT.get(ui.keys["play"]),
            _FKEY_TO_PYNPUT.get(ui.keys["save"]),
            _FKEY_TO_PYNPUT.get(ui.keys["open"]),
        } - {None}
    except Exception:
        # Fallback to defaults if UI not ready
        return {
            keyboard.Key.f3,
            keyboard.Key.f7,
            keyboard.Key.f4,
            keyboard.Key.f6,
        }

def should_ignore_key(k) -> bool:
    """Predicate you can wire into Recorder if supported."""
    if time.time() < _ignore_until:
        return True
    try:
        return k in get_control_keys()
    except Exception:
        return False

# ---- UI callbacks -------------------------------------------------------------

def start_rec():
    squelch()
    if player.playing:
        set_status("Can't record during playback.")
        return
    # Best-effort: hand our ignore info to Recorder if it supports it
    if hasattr(rec, "ignore_keys"):
        rec.ignore_keys = get_control_keys()
    if hasattr(rec, "set_key_filter"):
        try:
            rec.set_key_filter(should_ignore_key)
        except Exception:
            pass
    rec.start()
    set_status("Recording... (F8 to stop)")

def stop_rec():
    squelch()
    rec.stop()
    # refresh reference
    global macro_ref
    macro_ref = rec.macro
    set_status(f"Recorded {len(macro_ref.events)} events.")

def play(speed: float, loops: int, jitter: int):
    squelch()
    if rec.recording:
        set_status("Stop recording first.")
        return
    if player.playing:
        set_status("Already playing.")
        return

    def run():
        for _ in range(loops):
            if player.playing is False and _ > 0:
                break
            player.play(macro_ref, speed=speed, jitter_px=jitter, on_status=set_status)
            if player._stop_evt.is_set():
                break

    threading.Thread(target=run, daemon=True).start()

def stop_play():
    squelch()
    player.stop()
    set_status("Stopping playback...")

def get_macro() -> Macro:
    return macro_ref

def set_macro(m: Macro):
    global macro_ref
    macro_ref = m

# ---- Extra callbacks for Build / Prefs ---------------------------------------

def on_build():
    # optional: spawn PyInstaller, or just show README instructions
    import webbrowser
    webbrowser.open_new_tab("https://github.com/<you>/<repo>#packaging")

def on_prefs():
    # show a tiny dialog to edit speed/loops/jitter if you want (optional)
    ui.set_status("Prefs not implemented yet.")

# ---- UI ----------------------------------------------------------------------

ui = AppUI(
    on_start_rec=start_rec,
    on_stop_rec=stop_rec,
    on_play=play,
    on_stop_play=stop_play,
    on_get_macro=get_macro,
    on_set_macro=set_macro,
    on_build=on_build,     # 👈 here
    on_prefs=on_prefs,     # 👈 here
)

# ---- Global Hotkeys (use UI-configured F-keys) ------------------------------

def _ghk(label: str) -> str:
    """
    Convert 'F7' -> '<f7>' for GlobalHotKeys.
    """
    return f"<{label.lower()}>"

_bindings = {
    _ghk(ui.keys["record"]): lambda: (stop_rec() if rec.recording else start_rec()),
    _ghk(ui.keys["play"]):   lambda: play(
        speed=float(ui.speed_var.get() or "1.0"),
        loops=int(ui.loops_var.get() or "1"),
        jitter=int(ui.jitter_var.get() or "0"),
    ),
    _ghk(ui.keys["save"]):   ui._save,
    _ghk(ui.keys["open"]):   ui._load,
    '<esc>':                 stop_play,
}

hotkeys = keyboard.GlobalHotKeys(_bindings)
hotkeys.start()

# NOTE: If your Recorder implementation supports it, consider using:
#   rec.ignore_keys = get_control_keys()
#   rec.set_key_filter(should_ignore_key)
# to ensure UI control keys are never recorded.

# ---- Entry point --------------------------------------------------------------

if __name__ == "__main__":
    set_status("Ready. Grant Accessibility & Input Monitoring.")
    ui.run()