# SPDX-License-Identifier: GPL-3.0-or-later
import threading
import random
from typing import Callable
from pynput import mouse, keyboard
from models import Macro
from utils import str_to_button, str_to_key

class Player:
    """
    Plays back a recorded Macro with timing, speed, and jitter.
    Uses Event.wait(timeout) to avoid CPU spin.
    """
    def __init__(self) -> None:
        self._stop_evt = threading.Event()
        self._playing = False
        self._mouse = mouse.Controller()
        self._kbd = keyboard.Controller()

    @property
    def playing(self) -> bool:
        return self._playing

    def stop(self) -> None:
        self._stop_evt.set()

    def play(self, macro: Macro, speed: float = 1.0, jitter_px: int = 0,
             on_status: Callable[[str], None] = lambda _msg: None) -> None:
        if not macro.events:
            on_status("Nothing to play.")
            return

        self._playing = True
        self._stop_evt.clear()
        on_status("Playing... (ESC to stop)")

        # Precompute waits (scaled by speed)
        waits = []
        prev = 0.0
        for e in macro.events:
            dt = max(0.0, (e.t - prev) / max(1e-6, speed))
            waits.append(dt)
            prev = e.t

        for e, wait in zip(macro.events, waits):
            if self._stop_evt.is_set():
                break
            # Wait without spinning CPU
            self._stop_evt.wait(timeout=wait)
            if self._stop_evt.is_set():
                break

            try:
                if e.kind == "move":
                    x = int(e.data["x"]); y = int(e.data["y"])
                    if jitter_px > 0:
                        x += random.randint(-jitter_px, jitter_px)
                        y += random.randint(-jitter_px, jitter_px)
                    self._mouse.position = (x, y)

                elif e.kind == "click":
                    x = int(e.data["x"]); y = int(e.data["y"])
                    btn = str_to_button(e.data["button"])
                    pressed = bool(e.data["pressed"])
                    if jitter_px > 0:
                        x += random.randint(-jitter_px, jitter_px)
                        y += random.randint(-jitter_px, jitter_px)
                    self._mouse.position = (x, y)
                    if pressed:
                        self._mouse.press(btn)
                    else:
                        self._mouse.release(btn)

                elif e.kind == "scroll":
                    self._mouse.scroll(int(e.data.get("dx", 0)), int(e.data.get("dy", 0)))

                elif e.kind == "kpress":
                    k = str_to_key(e.data["key"])
                    if k is not None:
                        self._kbd.press(k)

                elif e.kind == "krelease":
                    k = str_to_key(e.data["key"])
                    if k is not None:
                        self._kbd.release(k)

            except Exception as ex:
                on_status(f"Playback error: {ex}")

        self._playing = False
        on_status("Playback finished.")