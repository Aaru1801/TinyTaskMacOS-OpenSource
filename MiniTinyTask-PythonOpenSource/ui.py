# SPDX-License-Identifier: GPL-3.0-or-later
"""
Modern card-style UI for MiniTinyTask (macOS)

- Big 'Start Recording' button (colored via ttk styles)
- 'Add to Favorites' and 'My Favorites' dialogs
- Tracking toggles
- Settings modal to customize keyboard shortcuts (Record / Play)
- Status section with tips
- Keeps StringVars (speed/loops/jitter) for compatibility with main.py

Storage:
- ~/.minitinytask/config.json      (shortcut keys)
- ~/.minitinytask/favorites.json   (named macros)
"""

import os
import json
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog
from tkinter import ttk
from dataclasses import asdict
from typing import Callable, Dict, Any
from models import Macro, Event

APP_DIR = os.path.join(os.path.expanduser("~"), ".minitinytask")
CONFIG_PATH = os.path.join(APP_DIR, "config.json")
FAVES_PATH  = os.path.join(APP_DIR, "favorites.json")

# Unregistered-by-default combos (very low collision risk)
DEFAULT_CONFIG = {
    "shortcut_record": "<Option-Shift-r>",  # macOS preferred (with Alt+Shift fallback)
    "shortcut_play":   "<Option-Shift-p>",
}

def _ensure_app_dir():
    os.makedirs(APP_DIR, exist_ok=True)

def _load_json(path: str, default: Any):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

def _save_json(path: str, data: Any):
    _ensure_app_dir()
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

# --- Shortcut helpers (pretty ↔ internal) ---
def _pretty_shortcut(seq: str) -> str:
    mapping = {
        "<Option-Shift-r>": "⌥⇧R",
        "<Alt-Shift-r>":    "Alt+Shift+R",
        "<Option-Shift-p>": "⌥⇧P",
        "<Alt-Shift-p>":    "Alt+Shift+P",
        "<Option-Shift-o>": "⌥⇧O",
        "<Alt-Shift-o>":    "Alt+Shift+O",
        "<Option-Shift-s>": "⌥⇧S",
        "<Alt-Shift-s>":    "Alt+Shift+S",
    }
    return mapping.get(seq, seq)

def _parse_shortcut(label: str) -> str:
    reverse = {
        "⌥⇧R": "<Option-Shift-r>",
        "Alt+Shift+R": "<Alt-Shift-r>",
        "⌥⇧P": "<Option-Shift-p>",
        "Alt+Shift+P": "<Alt-Shift-p>",
        "⌥⇧O": "<Option-Shift-o>",
        "Alt+Shift+O": "<Alt-Shift-o>",
        "⌥⇧S": "<Option-Shift-s>",
        "Alt+Shift+S": "<Alt-Shift-s>",
    }
    return reverse.get(label, label)

# ---------------- UI ----------------
PRIMARY_GREEN  = "#22c55e"
PRIMARY_BLUE   = "#3b82f6"
PRIMARY_YELLOW = "#facc15"
SURFACE        = "#f3f4f6"  # light gray
TEXT_DARK      = "#1f2937"
TEXT_MUTED     = "#4b5563"

class AppUI:
    def __init__(
        self,
        on_start_rec: Callable[[], None],
        on_stop_rec:  Callable[[], None],
        on_play:      Callable[[float, int, int], None],
        on_stop_play: Callable[[], None],
        on_get_macro: Callable[[], Macro],
        on_set_macro: Callable[[Macro], None],
        on_build:     Callable[[], None] | None = None,
        on_prefs:     Callable[[], None] | None = None,
        on_set_tracking: Callable[[bool, bool], None] | None = None,
    ) -> None:
        # Callbacks
        self._on_start_rec = on_start_rec
        self._on_stop_rec  = on_stop_rec
        self._on_play      = on_play
        self._on_stop_play = on_stop_play
        self._on_get_macro = on_get_macro
        self._on_set_macro = on_set_macro
        self._on_build     = on_build or (lambda: messagebox.showinfo("Build", "See README for packaging instructions."))
        self._on_prefs     = on_prefs or (lambda: messagebox.showinfo("Preferences", "Nothing here yet."))
        self._on_set_tracking = on_set_tracking

        # Window
        self.root = tk.Tk()
        self.root.title("TinyTask")
        self.root.configure(bg=SURFACE)
        self.root.resizable(False, False)

        # Playback defaults
        self.speed = 1.0
        self.loops = 1
        self.jitter = 0

        # Keep StringVars for compatibility with main.py hotkeys
        self.speed_var  = tk.StringVar(master=self.root, value=str(self.speed))
        self.loops_var  = tk.StringVar(master=self.root, value=str(self.loops))
        self.jitter_var = tk.StringVar(master=self.root, value=str(self.jitter))

        self.current_filename = "Ready"
        self._recording = False

        # State: toggles
        self.track_mouse = tk.BooleanVar(master=self.root, value=True)
        self.track_keys  = tk.BooleanVar(master=self.root, value=True)

        # Config + Favorites
        _ensure_app_dir()
        self.config    = _load_json(CONFIG_PATH, DEFAULT_CONFIG.copy())
        self.favorites = _load_json(FAVES_PATH, {})

        # Build the UI and bind shortcuts
        self._build_ui()
        self._bind_shortcuts()

    # Public wrapper so main.py can call ui.set_status(...)
    def set_status(self, msg: str) -> None:
        self.status.config(text=msg)
        print(msg)

    # ---------- Layout ----------
    def _build_ui(self):
        pad = 18

        # --- ttk theme & styles (Aqua ignores bg on tk.Button; 'clam' respects it) ---
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except Exception:
            pass

        style.configure("Primary.TButton",
                        foreground="white", background=PRIMARY_GREEN,
                        padding=12, font=("Helvetica", 16, "bold"))
        style.map("Primary.TButton",
                  background=[("active", "#16a34a")])

        style.configure("Info.TButton",
                        foreground="white", background=PRIMARY_BLUE,
                        padding=10, font=("Helvetica", 13, "bold"))
        style.map("Info.TButton",
                  background=[("active", "#2563eb")])

        style.configure("Warn.TButton",
                        foreground=TEXT_DARK, background=PRIMARY_YELLOW,
                        padding=10, font=("Helvetica", 13, "bold"))
        style.map("Warn.TButton",
                  background=[("active", "#eab308")])

        style.configure("Danger.TButton",
                        foreground="white", background="#ef4444",
                        padding=12, font=("Helvetica", 16, "bold"))
        style.map("Danger.TButton",
                  background=[("active", "#dc2626")])

        # Header row
        header = tk.Frame(self.root, bg=SURFACE)
        header.pack(fill="x", padx=pad, pady=(pad, 8))

        title = tk.Label(header, text="TinyTask", bg=SURFACE, fg=TEXT_DARK,
                         font=("Helvetica", 22, "bold"))
        title.pack(side="left")

        # Settings "gear"
        ttk.Button(header, text="⚙️", width=3, command=self._open_settings).pack(side="right")

        # Big Start/Stop button
        btn_wrap = tk.Frame(self.root, bg=SURFACE)
        btn_wrap.pack(fill="x", padx=pad, pady=(22, 0))

        self.rec_btn = ttk.Button(
            btn_wrap, text="Start Recording",
            style="Primary.TButton",
            command=self._toggle_record
        )
        self.rec_btn.pack(fill="x")

        # Row: Add to Favorites / My Favorites
        fav_row = tk.Frame(self.root, bg=SURFACE)
        fav_row.pack(fill="x", padx=pad, pady=(20, 0))

        add_btn = ttk.Button(
            fav_row, text="Add to Favorites",
            style="Warn.TButton",
            command=self._add_favorite
        )
        add_btn.pack(side="left")

        my_btn = ttk.Button(
            fav_row, text="My Favorites",
            style="Info.TButton",
            command=self._open_favorites
        )
        my_btn.pack(side="left", padx=(12, 0))

        # Tracking options
        track_box = tk.Frame(self.root, bg=SURFACE)
        track_box.pack(fill="x", padx=pad, pady=(26, 0))

        tk.Label(track_box, text="Tracking Options", bg=SURFACE, fg=TEXT_DARK,
                 font=("Helvetica", 16, "bold")).pack(anchor="w")

        tk.Checkbutton(
            track_box, text="Track Mouse Movements", bg=SURFACE, fg=TEXT_DARK,
            variable=self.track_mouse, activebackground=SURFACE,
            onvalue=True, offvalue=False, command=self._apply_tracking
        ).pack(anchor="w", pady=(10, 0))

        tk.Checkbutton(
            track_box, text="Track Keyboard Keys", bg=SURFACE, fg=TEXT_DARK,
            variable=self.track_keys, activebackground=SURFACE,
            onvalue=True, offvalue=False, command=self._apply_tracking
        ).pack(anchor="w", pady=(6, 0))

        # Status section
        status_box = tk.Frame(self.root, bg=SURFACE)
        status_box.pack(fill="x", padx=pad, pady=(28, pad))

        tk.Label(status_box, text="Status", bg=SURFACE, fg=TEXT_DARK,
                 font=("Helvetica", 16, "bold")).pack(anchor="w")

        self.status = tk.Label(
            status_box,
            text="Ready\nPress '⌥⇧S' to save / '⌥⇧O' to open\nRecord '⌥⇧R' • Play '⌥⇧P'",
            bg=SURFACE, fg=TEXT_MUTED, justify="center"
        )
        self.status.pack(fill="x", pady=(8, 0))

    # ---------- Favorite Macros ----------
    def _add_favorite(self):
        macro = self._on_get_macro()
        if not macro.events:
            messagebox.showinfo("Favorites", "No macro to save. Record one first.")
            return
        name = simpledialog.askstring("Add to Favorites", "Favorite name:", parent=self.root)
        if not name:
            return
        self.favorites[name] = {
            "version": 1,
            "events": [asdict(e) for e in macro.events],
        }
        _save_json(FAVES_PATH, self.favorites)
        self._set_status(f"Saved favorite '{name}'.")

    def _open_favorites(self):
        win = tk.Toplevel(self.root)
        win.title("Favorite Macros")
        win.configure(bg=SURFACE)
        win.resizable(False, False)

        pad = 14
        tk.Label(win, text="My Favorite Macros", bg=SURFACE, fg=TEXT_DARK,
                 font=("Helvetica", 16, "bold")).pack(anchor="w", padx=pad, pady=(pad, 8))

        frame = tk.Frame(win, bg=SURFACE)
        frame.pack(fill="both", expand=True, padx=pad, pady=(0, pad))

        lb = tk.Listbox(frame, height=10)
        lb.pack(fill="both", expand=True)
        for name in sorted(self.favorites.keys()):
            lb.insert(tk.END, name)

        row = tk.Frame(win, bg=SURFACE)
        row.pack(fill="x", padx=pad, pady=(0, pad))

        def play_sel():
            try:
                idx = lb.curselection()[0]
            except IndexError:
                return
            name = lb.get(idx)
            fav = self.favorites.get(name)
            if not fav:
                return
            events = [Event(t=float(e["t"]), kind=e["kind"], data=e["data"]) for e in fav.get("events", [])]
            self._on_set_macro(Macro(events=events))
            self._set_status(f"Loaded favorite '{name}'. Playing…")
            self._ensure_numeric_defaults()
            self._on_play(self.speed, self.loops, self.jitter)

        def delete_sel():
            try:
                idx = lb.curselection()[0]
            except IndexError:
                return
            name = lb.get(idx)
            if messagebox.askyesno("Delete Favorite", f"Delete '{name}'?"):
                self.favorites.pop(name, None)
                _save_json(FAVES_PATH, self.favorites)
                lb.delete(idx)

        ttk.Button(row, text="Play",   style="Primary.TButton", command=play_sel).pack(side="left")
        ttk.Button(row, text="Delete", style="Danger.TButton",  command=delete_sel).pack(side="right")

    # ---------- Settings ----------
    def _open_settings(self):
        win = tk.Toplevel(self.root)
        win.title("Settings")
        win.configure(bg=SURFACE)
        win.resizable(False, False)

        pad = 16
        tk.Label(win, text="Shortcut Keys", bg=SURFACE, fg=TEXT_DARK,
                 font=("Helvetica", 16, "bold")).pack(anchor="w", padx=pad, pady=(pad, 6))

        form = tk.Frame(win, bg=SURFACE)
        form.pack(fill="x", padx=pad)

        tk.Label(form, text="Record:", bg=SURFACE, fg=TEXT_DARK).grid(row=0, column=0, sticky="w", pady=6)
        tk.Label(form, text="Play:",   bg=SURFACE, fg=TEXT_DARK).grid(row=1, column=0, sticky="w", pady=6)

        rec_var = tk.StringVar(master=win, value=_pretty_shortcut(self.config.get("shortcut_record", DEFAULT_CONFIG["shortcut_record"])))
        ply_var = tk.StringVar(master=win, value=_pretty_shortcut(self.config.get("shortcut_play",   DEFAULT_CONFIG["shortcut_play"])))

        rec_entry = tk.Entry(form, textvariable=rec_var, width=22)
        ply_entry = tk.Entry(form, textvariable=ply_var, width=22)
        rec_entry.grid(row=0, column=1, sticky="w", padx=(10,0), pady=6)
        ply_entry.grid(row=1, column=1, sticky="w", padx=(10,0), pady=6)

        btns = tk.Frame(win, bg=SURFACE)
        btns.pack(fill="x", padx=pad, pady=(10, pad))

        def reset():
            rec_var.set(_pretty_shortcut(DEFAULT_CONFIG["shortcut_record"]))
            ply_var.set(_pretty_shortcut(DEFAULT_CONFIG["shortcut_play"]))

        def save():
            self.config["shortcut_record"] = _parse_shortcut(rec_var.get().strip()) or DEFAULT_CONFIG["shortcut_record"]
            self.config["shortcut_play"]   = _parse_shortcut(ply_var.get().strip()) or DEFAULT_CONFIG["shortcut_play"]
            _save_json(CONFIG_PATH, self.config)
            self._bind_shortcuts()
            messagebox.showinfo("Settings", "Shortcuts updated.")
            win.destroy()

        ttk.Button(btns, text="Reset To Defaults", command=reset).pack(side="left", padx=(0,8))
        ttk.Button(btns, text="Save",  command=save).pack(side="right")

    def _bind_shortcuts(self):
        # Clear previous
        for seq in [
            "<Command-s>","<Control-s>","<Command-r>","<Control-r>",
            "<Command-o>","<Control-o>","<Command-p>","<Control-p>",
            "<Option-Shift-r>","<Alt-Shift-r>","<Option-Shift-p>","<Alt-Shift-p>",
            "<Option-Shift-o>","<Alt-Shift-o>","<Option-Shift-s>","<Alt-Shift-s>",
        ]:
            try:
                self.root.unbind_all(seq)
            except Exception:
                pass

        # Read config (record/play), open/save are fixed to unregistered combos too
        rec = self.config.get("shortcut_record", DEFAULT_CONFIG["shortcut_record"])
        ply = self.config.get("shortcut_play",   DEFAULT_CONFIG["shortcut_play"])

        # Primary (mac) + fallback (other OSes)
        self.root.bind_all(rec,               lambda e: self._toggle_record())
        self.root.bind_all("<Alt-Shift-r>",   lambda e: self._toggle_record())

        self.root.bind_all(ply,               lambda e: self._play_clicked())
        self.root.bind_all("<Alt-Shift-p>",   lambda e: self._play_clicked())

        # Open/Save fixed unregistered bindings
        self.root.bind_all("<Option-Shift-o>", lambda e: self._load())
        self.root.bind_all("<Alt-Shift-o>",    lambda e: self._load())
        self.root.bind_all("<Option-Shift-s>", lambda e: self._save())
        self.root.bind_all("<Alt-Shift-s>",    lambda e: self._save())

    # ---------- Actions / helpers ----------
    def _toggle_record(self):
        if self._recording:
            self._on_stop_rec()
            self._recording = False
            self.rec_btn.config(text="Start Recording", style="Primary.TButton")
            self._set_status("Recording stopped.")
        else:
            self._on_start_rec()
            self._recording = True
            self.rec_btn.config(text="Stop Recording", style="Danger.TButton")
            self._set_status("Recording...")

    def _play_clicked(self):
        self._set_status("Playing…")
        self._ensure_numeric_defaults()
        self._on_play(self.speed, self.loops, self.jitter)

    def _ensure_numeric_defaults(self):
        try: self.speed = float(self.speed_var.get())
        except Exception: self.speed = 1.0
        try: self.loops = int(self.loops_var.get())
        except Exception: self.loops = 1
        try: self.jitter = int(self.jitter_var.get())
        except Exception: self.jitter = 0

    def _apply_tracking(self):
        if self._on_set_tracking:
            try:
                self._on_set_tracking(self.track_mouse.get(), self.track_keys.get())
            except Exception:
                pass

    # ---------- File ops ----------
    def _save(self):
        macro = self._on_get_macro()
        if not macro.events:
            self._set_status("Nothing to save.")
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".json",
            filetypes=[("Macro JSON", "*.json")],
            title="Save Macro"
        )
        if not path:
            return
        payload = {"version": 1, "events": [asdict(e) for e in macro.events]}
        with open(path, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        self.current_filename = os.path.basename(path)
        self._set_status(f"Saved {len(macro.events)} events → {self.current_filename}")

    def _load(self):
        path = filedialog.askopenfilename(filetypes=[("Macro JSON", "*.json")], title="Load Macro")
        if not path:
            return
        with open(path, "r", encoding="utf-8") as f:
            payload = json.load(f)
        events = [Event(t=float(e["t"]), kind=e["kind"], data=e["data"]) for e in payload.get("events", [])]
        self._on_set_macro(Macro(events=events))
        self.current_filename = os.path.basename(path)
        self._set_status(f"Loaded {len(events)} events ← {self.current_filename}")

    # ---------- Status (internal) ----------
    def _set_status(self, msg: str):
        self.status.config(text=msg)
        print(msg)

    # ---------- Mainloop ----------
    def run(self):
        self.root.mainloop()