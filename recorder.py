# SPDX-License-Identifier: GPL-3.0-or-later
from typing import Optional, Tuple, List
from pynput import mouse, keyboard
from models import Event, Macro
from utils import RecClock, button_to_str, key_to_str

class Recorder:
    """
    Records global mouse/keyboard events using pynput.
    """
    def __init__(self, move_min_interval: float = 0.01) -> None:
        self.clock = RecClock()
        self.move_min_interval = move_min_interval  # seconds
        self._last_move_t: float = 0.0
        self._last_pos: Optional[Tuple[int, int]] = None
        self._recording: bool = False
        self.macro: Macro = Macro(events=[])
        self._m_listener = None
        self._k_listener = None

        self.IGNORE_KEYS = {
            keyboard.Key.f8, keyboard.Key.f9, keyboard.Key.f10,
            keyboard.Key.f11, keyboard.Key.esc
        }

    # ---- lifecycle ----
    def start(self) -> None:
        if self._recording:
            return
        self.macro = Macro(events=[])
        self.clock.start()
        self._last_move_t = 0.0
        self._last_pos = None
        self._recording = True

    def stop(self) -> None:
        self._recording = False

    @property
    def recording(self) -> bool:
        return self._recording

    # ---- listeners ----
    def attach(self) -> None:
        if self._m_listener or self._k_listener:
            return
        self._m_listener = mouse.Listener(
            on_move=self._on_move, on_click=self._on_click, on_scroll=self._on_scroll
        )
        self._k_listener = keyboard.Listener(
            on_press=self._on_key_press, on_release=self._on_key_release
        )
        self._m_listener.daemon = True
        self._k_listener.daemon = True
        self._m_listener.start()
        self._k_listener.start()

    # ---- handlers ----
    def _now(self) -> float:
        return self.clock.now_rel()

    def _on_move(self, x, y):
        if not self._recording:
            return
        t = self._now()
        if (t - self._last_move_t) < self.move_min_interval:
            return
        if self._last_pos == (x, y):
            return
        self._last_move_t = t
        self._last_pos = (x, y)
        self.macro.events.append(Event(t=t, kind="move", data={"x": int(x), "y": int(y)}))

    def _on_click(self, x, y, button, pressed):
        if not self._recording:
            return
        self.macro.events.append(Event(
            t=self._now(), kind="click",
            data={"x": int(x), "y": int(y), "button": button_to_str(button), "pressed": bool(pressed)}
        ))

    def _on_scroll(self, x, y, dx, dy):
        if not self._recording:
            return
        self.macro.events.append(Event(
            t=self._now(), kind="scroll", data={"x": int(x), "y": int(y), "dx": int(dx), "dy": int(dy)}
        ))

    def _on_key_press(self, k):
        if not self._recording or k in self.IGNORE_KEYS:
            return
        self.macro.events.append(Event(t=self._now(), kind="kpress", data={"key": key_to_str(k)}))

    def _on_key_release(self, k):
        if not self._recording or k in self.IGNORE_KEYS:
            return
        self.macro.events.append(Event(t=self._now(), kind="krelease", data={"key": key_to_str(k)}))