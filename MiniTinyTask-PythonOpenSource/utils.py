# SPDX-License-Identifier: GPL-3.0-or-later
import time
from typing import Any, Dict, Optional
from pynput import keyboard, mouse

# ---- Timing helpers -------------------------------------------------

class RecClock:
    """Keeps a relative clock anchored at start()."""
    def __init__(self) -> None:
        self._t0: Optional[float] = None

    def start(self) -> None:
        self._t0 = time.perf_counter()

    def now_rel(self) -> float:
        if self._t0 is None:
            self.start()
        return time.perf_counter() - (self._t0 or time.perf_counter())

# ---- Serialization helpers -----------------------------------------

def key_to_str(k: Any) -> str:
    """Serialize pynput key/char to a stable string."""
    # character keys
    if hasattr(k, "char") and k.char is not None:
        return f"char:{k.char}"
    # named keys (esc, cmd, shift, etc.)
    try:
        name = getattr(k, "name")  # e.g., "space"
        if name:
            return f"key:{name}"
    except Exception:
        pass
    # fallback to string form
    return f"key:{str(k)}"

def str_to_key(s: str):
    """Deserialize string to pynput key/char. Returns None if unknown."""
    if s.startswith("char:"):
        return s.split(":", 1)[1]
    if s.startswith("key:"):
        name = s.split(":", 1)[1]
        # preferred dict lookup
        try:
            return keyboard.Key[name]
        except Exception:
            # try to parse 'Key.space' style
            if name.startswith("Key."):
                name = name.split(".", 1)[1]
                try:
                    return keyboard.Key[name]
                except Exception:
                    return None
    return None

def button_to_str(b: mouse.Button) -> str:
    if b == mouse.Button.left:
        return "left"
    if b == mouse.Button.right:
        return "right"
    if b == mouse.Button.middle:
        return "middle"
    return str(b)

def str_to_button(s: str) -> mouse.Button:
    return {
        "left": mouse.Button.left,
        "right": mouse.Button.right,
        "middle": mouse.Button.middle,
    }.get(s, mouse.Button.left)