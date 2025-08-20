#!/usr/bin/env python3
import json
import threading
import time
import os
import random
from dataclasses import dataclass, asdict
from typing import List, Optional, Any, Dict

# GUI
import tkinter as tk
from tkinter import filedialog, messagebox

# Input
from pynput import mouse, keyboard

# ----------------------- Data structures -----------------------

@dataclass
class Event:
    t: float  # seconds since start of recording
    kind: str # 'move', 'click', 'scroll', 'kpress', 'krelease'
    data: Dict[str, Any]

@dataclass
class Macro:
    events: List[Event]

# ----------------------- Global state --------------------------

macro: Macro = Macro(events=[])
recording = False
playing = False

_rec_start_time: Optional[float] = None

# for throttling move events
_last_move_time = 0.0
_MOVE_MIN_INTERVAL = 0.01  # 10ms
_last_move_pos = None

stop_play_event = threading.Event()

# Pynput controllers
mouse_controller = mouse.Controller()
keyboard_controller = keyboard.Controller()

# Hotkeys (set later)
hotkeys: Optional[keyboard.GlobalHotKeys] = None

# UI references
root = None
speed_var = None
loops_var = None
jitter_var = None
status_label = None

# Keys to ignore during recording (so toggles aren't captured)
IGNORE_KEYS = {keyboard.Key.f8, keyboard.Key.f9, keyboard.Key.f10, keyboard.Key.f11, keyboard.Key.esc}

# ----------------------- Helpers -------------------------------

def _now_rel() -> float:
    return time.perf_counter() - (_rec_start_time or time.perf_counter())

def _key_to_str(k) -> str:
    # Convert pynput key to a JSON-serializable string
    try:
        if hasattr(k, 'char') and k.char is not None:
            return f'char:{k.char}'
    except Exception:
        pass
    return f'key:{str(k)}'  # e.g., 'key:Key.space', 'key:Key.cmd'

def _str_to_key(s: str):
    # Convert stored string back to pynput key/char
    if s.startswith('char:'):
        return s.split(':', 1)[1]
    if s.startswith('key:'):
        name = s.split(':', 1)[1]  # 'Key.space'
        if name.startswith('Key.'):
            keyname = name.split('.', 1)[1]
            # special case because str(Key.cmd) can be 'Key.cmd'
            return getattr(keyboard.Key, keyname, None)
    return None

def _button_to_str(b: mouse.Button) -> str:
    # e.g., 'Button.left' -> 'left'
    if b == mouse.Button.left:
        return 'left'
    if b == mouse.Button.right:
        return 'right'
    if b == mouse.Button.middle:
        return 'middle'
    return str(b)

def _str_to_button(s: str) -> mouse.Button:
    return {'left': mouse.Button.left, 'right': mouse.Button.right, 'middle': mouse.Button.middle}.get(s, mouse.Button.left)

# ----------------------- Recording -----------------------------

def start_recording():
    global recording, macro, _rec_start_time, _last_move_time, _last_move_pos
    if playing:
        _set_status("Can't record during playback.")
        return
    macro = Macro(events=[])
    _rec_start_time = time.perf_counter()
    _last_move_time = 0.0
    _last_move_pos = None
    recording = True
    _set_status("Recording... (F8 to stop)")

def stop_recording():
    global recording
    recording = False
    _set_status(f"Recorded {len(macro.events)} events.")

def toggle_recording():
    if recording:
        stop_recording()
    else:
        start_recording()

def on_move(x, y):
    global _last_move_time, _last_move_pos
    if not recording:
        return
    t = _now_rel()
    # throttle move events
    if (t - _last_move_time) < _MOVE_MIN_INTERVAL:
        return
    _last_move_time = t
    if _last_move_pos == (x, y):
        return
    _last_move_pos = (x, y)
    macro.events.append(Event(t=t, kind='move', data={'x': x, 'y': y}))

def on_click(x, y, button, pressed):
    if not recording:
        return
    macro.events.append(Event(t=_now_rel(), kind='click',
                              data={'x': x, 'y': y, 'button': _button_to_str(button), 'pressed': bool(pressed)}))

def on_scroll(x, y, dx, dy):
    if not recording:
        return
    macro.events.append(Event(t=_now_rel(), kind='scroll',
                              data={'x': x, 'y': y, 'dx': int(dx), 'dy': int(dy)}))

def on_key_press(k):
    if not recording:
        return
    if k in IGNORE_KEYS:
        return
    macro.events.append(Event(t=_now_rel(), kind='kpress', data={'key': _key_to_str(k)}))

def on_key_release(k):
    if not recording:
        return
    if k in IGNORE_KEYS:
        return
    macro.events.append(Event(t=_now_rel(), kind='krelease', data={'key': _key_to_str(k)}))

# ----------------------- Playback ------------------------------

def _sleep_interval(dt: float):
    # more responsive sleep that checks stop flag
    end = time.perf_counter() + dt
    while time.perf_counter() < end:
        if stop_play_event.is_set():
            break
        time.sleep(min(0.01, end - time.perf_counter()))

def play_once(speed: float = 1.0, jitter: int = 0):
    if not macro.events:
        _set_status("Nothing to play. Record or load a macro first.")
        return
    global playing
    playing = True
    stop_play_event.clear()
    _set_status("Playing... (ESC to stop)")

    # precompute waits
    waits = []
    prev_t = 0.0
    for e in macro.events:
        waits.append(max(0.0, (e.t - prev_t) / max(1e-6, speed)))
        prev_t = e.t

    for e, wait in zip(macro.events, waits):
        if stop_play_event.is_set():
            break
        if wait > 0:
            _sleep_interval(wait)
        if stop_play_event.is_set():
            break

        try:
            if e.kind == 'move':
                x = int(e.data['x'])
                y = int(e.data['y'])
                if jitter > 0:
                    x += random.randint(-jitter, jitter)
                    y += random.randint(-jitter, jitter)
                mouse_controller.position = (x, y)

            elif e.kind == 'click':
                x = int(e.data['x'])
                y = int(e.data['y'])
                btn = _str_to_button(e.data['button'])
                pressed = bool(e.data['pressed'])
                if jitter > 0:
                    x += random.randint(-jitter, jitter)
                    y += random.randint(-jitter, jitter)
                mouse_controller.position = (x, y)
                if pressed:
                    mouse_controller.press(btn)
                else:
                    mouse_controller.release(btn)

            elif e.kind == 'scroll':
                dx = int(e.data.get('dx', 0))
                dy = int(e.data.get('dy', 0))
                mouse_controller.scroll(dx, dy)

            elif e.kind == 'kpress':
                key = _str_to_key(e.data['key'])
                if key is None:
                    continue
                keyboard_controller.press(key)

            elif e.kind == 'krelease':
                key = _str_to_key(e.data['key'])
                if key is None:
                    continue
                keyboard_controller.release(key)
        except Exception as ex:
            # continue even if a single event fails
            print("Playback error:", ex)

    playing = False
    _set_status("Playback finished.")

def start_playback():
    try:
        speed = float(speed_var.get())
    except Exception:
        speed = 1.0
    try:
        loops = int(loops_var.get())
    except Exception:
        loops = 1
    try:
        jitter = int(jitter_var.get())
    except Exception:
        jitter = 0

    if loops < 1:
        loops = 1
    if speed <= 0:
        speed = 1.0
    if jitter < 0:
        jitter = 0

    if recording:
        _set_status("Stop recording first.")
        return
    if playing:
        _set_status("Already playing.")
        return

    def run():
        for i in range(loops):
            if stop_play_event.is_set():
                break
            play_once(speed=speed, jitter=jitter)

    threading.Thread(target=run, daemon=True).start()

def stop_playback():
    stop_play_event.set()
    _set_status("Stopping playback...")

# ----------------------- Save/Load ------------------------------

def save_macro():
    if not macro.events:
        _set_status("Nothing to save.")
        return
    path = filedialog.asksaveasfilename(
        defaultextension=".json",
        filetypes=[("Macro JSON", "*.json")],
        title="Save Macro"
    )
    if not path:
        return
    payload = {
        "version": 1,
        "events": [asdict(e) for e in macro.events],
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    _set_status(f"Saved {len(macro.events)} events to {os.path.basename(path)}.")

def load_macro():
    global macro
    path = filedialog.askopenfilename(
        filetypes=[("Macro JSON", "*.json")],
        title="Load Macro"
    )
    if not path:
        return
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    events = []
    for e in payload.get("events", []):
        events.append(Event(t=float(e["t"]), kind=e["kind"], data=e["data"]))
    macro = Macro(events=events)
    _set_status(f"Loaded {len(macro.events)} events from {os.path.basename(path)}.")

# ----------------------- UI ------------------------------

def _set_status(msg: str):
    if status_label is not None:
        status_label.config(text=msg)
    print(msg)

def build_ui():
    global root, speed_var, loops_var, jitter_var, status_label
    root = tk.Tk()
    root.title("MiniTinyTask (mac)")
    root.geometry("340x190")
    root.resizable(False, False)

    frm = tk.Frame(root, padx=10, pady=10)
    frm.pack(fill="both", expand=True)

    # Controls row
    row0 = tk.Frame(frm)
    row0.pack(fill="x", pady=(0, 8))
    tk.Button(row0, text="Start Rec (F8)", command=start_recording, width=14).pack(side="left", padx=(0, 8))
    tk.Button(row0, text="Stop Rec (F8)", command=stop_recording, width=14).pack(side="left")

    row1 = tk.Frame(frm)
    row1.pack(fill="x", pady=(0, 8))
    tk.Button(row1, text="Play (F9)", command=start_playback, width=14).pack(side="left", padx=(0, 8))
    tk.Button(row1, text="Stop Play (ESC)", command=stop_playback, width=14).pack(side="left")

    # Params
    row2 = tk.Frame(frm)
    row2.pack(fill="x", pady=(0, 8))
    tk.Label(row2, text="Speed x").pack(side="left", padx=(0, 6))
    speed_var = tk.StringVar(value="1.0")
    tk.Entry(row2, textvariable=speed_var, width=6).pack(side="left", padx=(0, 12))

    tk.Label(row2, text="Loops").pack(side="left", padx=(0, 6))
    loops_var = tk.StringVar(value="1")
    tk.Entry(row2, textvariable=loops_var, width=6).pack(side="left", padx=(0, 12))

    tk.Label(row2, text="Jitter px").pack(side="left", padx=(0, 6))
    jitter_var = tk.StringVar(value="0")
    tk.Entry(row2, textvariable=jitter_var, width=6).pack(side="left")

    # Save/Load
    row3 = tk.Frame(frm)
    row3.pack(fill="x", pady=(0, 8))
    tk.Button(row3, text="Save (F10)", command=save_macro, width=14).pack(side="left", padx=(0, 8))
    tk.Button(row3, text="Load (F11)", command=load_macro, width=14).pack(side="left")

    status = tk.Frame(frm)
    status.pack(fill="x")
    status_label = tk.Label(status, text="Ready. Grant Accessibility & Input Monitoring.", anchor="w", justify="left")
    status_label.pack(fill="x")

    # Shortcuts hint
    hint = tk.Label(frm, text="Hotkeys: F8 Rec, F9 Play, F10 Save, F11 Load, ESC Stop", fg="#555")
    hint.pack(anchor="w", pady=(6, 0))

    return root

# ----------------------- Listeners & Hotkeys --------------------

def start_listeners():
    m_listener = mouse.Listener(on_move=on_move, on_click=on_click, on_scroll=on_scroll)
    k_listener = keyboard.Listener(on_press=on_key_press, on_release=on_key_release)

    m_listener.daemon = True
    k_listener.daemon = True
    m_listener.start()
    k_listener.start()

    # Global hotkeys
    global hotkeys
    hotkeys = keyboard.GlobalHotKeys({
        '<f8>': toggle_recording,
        '<f9>': start_playback,
        '<f10>': save_macro,
        '<f11>': load_macro,
        '<esc>': stop_playback,
    })
    hotkeys.start()

# ----------------------- Entry point ----------------------------

def main():
    start_listeners()
    ui = build_ui()
    ui.mainloop()

if __name__ == '__main__':
    main()
