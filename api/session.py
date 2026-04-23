"""In-memory session store for agent task tracking."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Optional
from uuid import uuid4

from agent.loop import AgentEvent, TokenUsage


@dataclass
class Session:
    id: str
    task: str
    created_at: float = field(default_factory=time.time)
    status: str = "pending"        # pending | running | done | error
    events: list[AgentEvent] = field(default_factory=list)
    usage: Optional[TokenUsage] = None
    error: Optional[str] = None
    # Subscribers waiting on new events (index into self.events)
    _cursors: list[int] = field(default_factory=list)

    def append_event(self, event: AgentEvent) -> None:
        self.events.append(event)
        if event.type == "usage":
            self.usage = event.data
        elif event.type == "error":
            self.error = event.data
        elif event.type == "done":
            self.status = "done"


# Module-level registry
_sessions: dict[str, Session] = {}


def create_session(task: str) -> Session:
    s = Session(id=str(uuid4()), task=task)
    _sessions[s.id] = s
    return s


def get_session(session_id: str) -> Optional[Session]:
    return _sessions.get(session_id)


def all_sessions() -> list[Session]:
    return list(_sessions.values())
