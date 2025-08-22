# SPDX-License-Identifier: GPL-3.0-or-later
"""
Modern card-style UI for MiniTinyTask (macOS)

- Big 'Start Recording' and 'Play Macro' buttons (ttk styles)
- 'Add to Favorites' and 'My Favorites' dialogs
- Tracking toggles
- Settings dialog with F-key capture (press an F key to assign)
- Status section with tips
- Keeps StringVars (speed/loops/jitter) for compatibility with main.py

Default F-key Shortcuts:
- F3  → Start/Stop Recording
- F7  → Play/Stop Playback
- F4  → Save Macro
- F6  → Open Macro

Storage:
- ~/.minitinytask/config.json      (F-key mappings)
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

APP_DIR   = os.path.join(os.path.expanduser("~"), ".minitinytask")
CONFIG    = os.path.join(APP_DIR, "config.json")
FAVES     = os.path.join(APP_DIR, "favorites.json")

# --- Defaults (F-keys) ---
DEFAULT_KEYS = {
    "record": "F3",
    "play":   "F7",
    "save":   "F4",
    "open":   "F6",
}

# Limit allowed keys to F1..F19 (covers extended keyboards)
ALLOWED_F_KEYS = {f"F{i}" for i in range(1, 20)}

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

# ---------------- UI palette (dark theme defaults) ----------------
BG_DARK       = "#0f141b"   # window background
SURFACE       = BG_DARK     # surface cards
TEXT_DARK     = "#e5e7eb"   # primary text
TEXT_MUTED    = "#9aa3af"   # secondary text

PRIMARY_GREEN  = "#22c55e"
PRIMARY_BLUE   = "#3b82f6"
PRIMARY_YELLOW = "#facc15"
DANGER_RED     = "#ef4444"

# ----- Theme presets -----
THEME_DARK = {
    "BG": "#0f141b",
    "SURFACE": "#0f141b",
    "TEXT": "#e5e7eb",
    "MUTED": "#9aa3af",
}
THEME_LIGHT = {
    "BG": "#f3f4f6",
    "SURFACE": "#f3f4f6",
    "TEXT": "#1f2937",
    "MUTED": "#4b5563",
}

def _set_theme_vars(mode: str):
    """
    Update module-level palette constants based on mode ('dark' or 'light').
    We mutate the module globals so subsequent widget builds use the new colors.
    """
    global BG_DARK, SURFACE, TEXT_DARK, TEXT_MUTED
    theme = THEME_DARK if (mode or '').lower() == "dark" else THEME_LIGHT
    BG_DARK   = theme["BG"]
    SURFACE   = theme["SURFACE"]
    TEXT_DARK = theme["TEXT"]
    TEXT_MUTED= theme["MUTED"]

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
        self.root.title("TinyTask (macOS)")
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
        self._playing   = False

        # State: toggles
        self.track_mouse = tk.BooleanVar(master=self.root, value=True)
        self.track_keys  = tk.BooleanVar(master=self.root, value=True)

        # Config + Favorites
        _ensure_app_dir()
        self.config = _load_json(CONFIG, {})
        # Appearance
        self.theme = (self.config.get("theme") or "dark").lower()
        if self.theme not in ("dark", "light"):
            self.theme = "dark"
        _set_theme_vars(self.theme)
        # Merge defaults (so new keys appear for existing users)
        self.keys: Dict[str, str] = {
            "record": self.config.get("key_record", DEFAULT_KEYS["record"]),
            "play":   self.config.get("key_play",   DEFAULT_KEYS["play"]),
            "save":   self.config.get("key_save",   DEFAULT_KEYS["save"]),
            "open":   self.config.get("key_open",   DEFAULT_KEYS["open"]),
        }
        self.favorites = _load_json(FAVES, {})

        # Build the UI and bind shortcuts
        self._build_ui()
        self._bind_shortcuts()

        # Ensure the window has focus so Tk receives key events
        self.root.after(150, self.root.focus_force)

    # Public wrapper so main.py can call ui.set_status(...)
    def set_status(self, msg: str) -> None:
        self.status.config(text=msg)
        print(msg)

    # ---------- Layout ----------
    def _build_ui(self):
        pad = 18
        self.root.configure(bg=SURFACE)

        # --- ttk theme & styles ---
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")  # predictable colors on macOS
        except Exception:
            pass

        # Primary colored buttons
        style.configure("Primary.TButton",
                        foreground="white", background=PRIMARY_GREEN,
                        padding=12, font=("Helvetica", 16, "bold"), borderwidth=0)
        style.map("Primary.TButton", background=[("active", "#16a34a")])

        style.configure("Info.TButton",
                        foreground="white", background=PRIMARY_BLUE,
                        padding=10, font=("Helvetica", 14, "bold"), borderwidth=0)
        style.map("Info.TButton", background=[("active", "#2563eb")])

        style.configure("Warn.TButton",
                        foreground=TEXT_DARK, background=PRIMARY_YELLOW,
                        padding=10, font=("Helvetica", 13, "bold"), borderwidth=0)
        style.map("Warn.TButton", background=[("active", "#eab308")])

        style.configure("Danger.TButton",
                        foreground="white", background=DANGER_RED,
                        padding=12, font=("Helvetica", 16, "bold"), borderwidth=0)
        style.map("Danger.TButton", background=[("active", "#dc2626")])

        # Neutral buttons (Settings dialog: Change / Reset / Save)
        neutral_fg = ("#ffffff" if self.theme == "dark" else "#111111")
        neutral_bg = ("#374151" if self.theme == "dark" else "#e5e7eb")  # slate / light gray
        neutral_active = ("#4b5563" if self.theme == "dark" else "#d1d5db")

        style.configure("Neutral.TButton",
                        foreground=neutral_fg, background=neutral_bg,
                        padding=8, font=("Helvetica", 12, "bold"), borderwidth=0)
        style.map("Neutral.TButton",
                  background=[("active", neutral_active)])

        # Header row
        header = tk.Frame(self.root, bg=SURFACE)
        header.pack(fill="x", padx=pad, pady=(pad, 8))

        title = tk.Label(header, text="TinyTask (macOS)", bg=SURFACE, fg=TEXT_DARK,
                         font=("Helvetica", 22, "bold"))
        title.pack(side="left")

        # Settings "gear"
        ttk.Button(header, text="⚙️", width=3, style="Neutral.TButton",
                   command=self._open_settings).pack(side="right")

        # Big Start/Stop + Play/Stop buttons
        btn_wrap = tk.Frame(self.root, bg=SURFACE)
        btn_wrap.pack(fill="x", padx=pad, pady=(22, 0))

        self.rec_btn = ttk.Button(
            btn_wrap, text="Start Recording",
            style="Primary.TButton",
            command=self._toggle_record
        )
        self.rec_btn.pack(fill="x")

        self.play_btn = ttk.Button(
            btn_wrap, text="Play Macro",
            style="Info.TButton",
            command=self._toggle_play
        )
        self.play_btn.pack(fill="x", pady=(10, 0))

        # Row: Add to Favorites / My Favorites
        fav_row = tk.Frame(self.root, bg=SURFACE)
        fav_row.pack(fill="x", padx=pad, pady=(20, 0))

        ttk.Button(
            fav_row, text="Add to Favorites",
            style="Warn.TButton",
            command=self._add_favorite
        ).pack(side="left")

        ttk.Button(
            fav_row, text="My Favorites",
            style="Info.TButton",
            command=self._open_favorites
        ).pack(side="left", padx=(12, 0))

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
            text=self._status_hint(),
            bg=SURFACE, fg=TEXT_MUTED, justify="center"
        )
        self.status.pack(fill="x", pady=(8, 0))

    def _status_hint(self) -> str:
        return (f"Ready\n"
                f"Record {self.keys['record']} • "
                f"Play {self.keys['play']} • "
                f"Save {self.keys['save']} • "
                f"Open {self.keys['open']}")

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
        _save_json(FAVES, self.favorites)
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
                _save_json(FAVES, self.favorites)
                lb.delete(idx)

        ttk.Button(row, text="Play",   style="Primary.TButton", command=play_sel).pack(side="left")
        ttk.Button(row, text="Delete", style="Danger.TButton",  command=delete_sel).pack(side="right")

    # ---------- Settings: F-key capture ----------
    def _open_settings(self):
        """Settings dialog that captures F-keys by pressing them."""
        win = tk.Toplevel(self.root)
        win.title("Keyboard Shortcuts")
        win.configure(bg=SURFACE)
        win.resizable(False, False)

        pad = 16
        tk.Label(win, text="Keyboard Shortcuts", bg=SURFACE, fg=TEXT_DARK,
                 font=("Helvetica", 16, "bold")).pack(anchor="w", padx=pad, pady=(pad, 6))

        hint = ("Click a field, then press an F-key (F1–F19) to assign. "
                "Duplicates are not allowed.")
        tk.Label(win, text=hint, bg=SURFACE, fg=TEXT_MUTED,
                 font=("Helvetica", 11)).pack(anchor="w", padx=pad, pady=(0, 10))

        form = tk.Frame(win, bg=SURFACE)
        form.pack(fill="x", padx=pad)

        rows = [
            ("Record", "record"),
            ("Play",   "play"),
            ("Save",   "save"),
            ("Open",   "open"),
        ]

        # Appearance group
        tk.Label(win, text="Appearance", bg=SURFACE, fg=TEXT_DARK,
                 font=("Helvetica", 14, "bold")).pack(anchor="w", padx=pad, pady=(12, 4))
        theme_frame = tk.Frame(win, bg=SURFACE)
        theme_frame.pack(fill="x", padx=pad)

        # Theme-aware radio colors
        if self.theme == "dark":
            radio_fg, radio_bg, selcolor = "#ffffff", SURFACE, BG_DARK
        else:
            radio_fg, radio_bg, selcolor = "#111111", SURFACE, "#ffffff"

        theme_var = tk.StringVar(master=win, value=self.theme)
        tk.Radiobutton(theme_frame, text="Light", value="light", variable=theme_var,
                       bg=radio_bg, fg=radio_fg, selectcolor=selcolor,
                       activebackground=radio_bg).pack(side="left", padx=(0,12))
        tk.Radiobutton(theme_frame, text="Dark", value="dark", variable=theme_var,
                       bg=radio_bg, fg=radio_fg, selectcolor=selcolor,
                       activebackground=radio_bg).pack(side="left")

        # State for capture
        self._capture_target: str | None = None
        self._key_labels: Dict[str, tk.Label] = {}

        def begin_capture(action_key: str):
            self._capture_target = action_key
            self._set_status(f"Press an F-key for {action_key.capitalize()}…")
            win.bind("<KeyPress>", on_keypress)

        def end_capture():
            try:
                win.unbind("<KeyPress>")
            except Exception:
                pass
            self._capture_target = None
            self._set_status("Ready.")

        def on_keypress(event: tk.Event):
            if not self._capture_target:
                return
            keysym = event.keysym
            if keysym not in ALLOWED_F_KEYS:
                messagebox.showwarning("Invalid key", "Please press a function key (F1–F19).")
                end_capture()
                return

            if keysym in self.keys.values():
                owner = next((k for k, v in self.keys.items() if v == keysym), None)
                if owner and owner != self._capture_target:
                    messagebox.showwarning("Duplicate key",
                                           f"{keysym} is already assigned to '{owner}'. Choose another.")
                    end_capture()
                    return

            self.keys[self._capture_target] = keysym
            self._key_labels[self._capture_target].config(text=keysym)
            end_capture()

        # Build rows with theme-aware contrast for the key "pills"
        for r, (title, keyname) in enumerate(rows):
            tk.Label(form, text=f"{title}:", bg=SURFACE, fg=TEXT_DARK,
                     font=("Helvetica", 12)).grid(row=r, column=0, sticky="w", pady=6)

            if self.theme == "dark":
                key_bg, key_fg = "#ffffff", "#000000"
            else:
                key_bg, key_fg = "#111111", "#ffffff"

            lbl = tk.Label(form, text=self.keys[keyname],
                           bg=key_bg, fg=key_fg,
                           bd=1, relief="solid", width=8,
                           font=("Helvetica", 12))
            lbl.grid(row=r, column=1, sticky="w", padx=(10, 8), pady=6)
            self._key_labels[keyname] = lbl

            ttk.Button(form, text="Change", style="Neutral.TButton",
                       command=lambda k=keyname: begin_capture(k)).grid(
                row=r, column=2, sticky="w", pady=6
            )

        # Save / Reset
        btns = tk.Frame(win, bg=SURFACE)
        btns.pack(fill="x", padx=pad, pady=(12, pad))

        def reset():
            for k, v in DEFAULT_KEYS.items():
                self.keys[k] = v
                self._key_labels[k].config(text=v)

        def save():
            # Persist keys
            self.config["key_record"] = self.keys["record"]
            self.config["key_play"]   = self.keys["play"]
            self.config["key_save"]   = self.keys["save"]
            self.config["key_open"]   = self.keys["open"]
            # Persist theme
            self.theme = theme_var.get().lower()
            if self.theme not in ("dark", "light"):
                self.theme = "dark"
            self.config["theme"] = self.theme
            _save_json(CONFIG, self.config)

            # Apply theme + rebind + refresh UI
            _set_theme_vars(self.theme)
            self._rebuild_for_theme()

            messagebox.showinfo("Settings", "Preferences updated.")
            win.destroy()

        ttk.Button(btns, text="Reset", style="Neutral.TButton",
                   command=reset).pack(side="left")
        ttk.Button(btns, text="Save",  style="Neutral.TButton",
                   command=save).pack(side="right")

    def _rebuild_for_theme(self):
        """Rebuild visible widgets after a theme change."""
        for child in self.root.winfo_children():
            try:
                child.destroy()
            except Exception:
                pass
        self._build_ui()
        self._bind_shortcuts()
        self.status.config(text=self._status_hint())
        self.root.after(50, self.root.focus_force)

    # ---------- F-key bindings ----------
    def _bind_shortcuts(self):
        # Unbind all possible F-keys we might have used previously
        for i in range(1, 20):
            try:
                self.root.unbind_all(f"<F{i}>")
            except Exception:
                pass

        # Bind current mappings
        self.root.bind_all(f"<{self.keys['record']}>", lambda e: self._toggle_record())
        self.root.bind_all(f"<{self.keys['play']}>",   lambda e: self._toggle_play())
        self.root.bind_all(f"<{self.keys['save']}>",   lambda e: self._save())
        self.root.bind_all(f"<{self.keys['open']}>",   lambda e: self._load())

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

    def _toggle_play(self):
        if self._playing:
            self._on_stop_play()
            self._playing = False
            self.play_btn.config(text="Play Macro", style="Info.TButton")
            self._set_status("Playback stopped.")
        else:
            self._set_status("Playing…")
            self._ensure_numeric_defaults()
            self._on_play(self.speed, self.loops, self.jitter)
            self._playing = True
            self.play_btn.config(text="Stop Playback", style="Danger.TButton")

    def _ensure_numeric_defaults(self):
        try:
            self.speed = float(self.speed_var.get())
        except Exception:
            self.speed = 1.0
        try:
            self.loops = int(self.loops_var.get())
        except Exception:
            self.loops = 1
        try:
            self.jitter = int(self.jitter_var.get())
        except Exception:
            self.jitter = 0

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
        I = len(events)
        self._set_status(f"Loaded {I} event{'s' if I != 1 else ''} ← {self.current_filename}")

    # ---------- Status (internal) ----------
    def _set_status(self, msg: str):
        self.status.config(text=msg)
        print(msg)

    # ---------- Mainloop ----------
    def run(self):
        self.root.mainloop()