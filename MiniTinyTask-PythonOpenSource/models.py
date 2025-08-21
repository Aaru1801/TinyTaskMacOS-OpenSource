# SPDX-License-Identifier: GPL-3.0-or-later
from dataclasses import dataclass
from typing import Any, Dict, List

@dataclass
class Event:
    t: float                 # seconds since the start of recording
    kind: str                # 'move','click','scroll','kpress','krelease'
    data: Dict[str, Any]

@dataclass
class Macro:
    events: List[Event]