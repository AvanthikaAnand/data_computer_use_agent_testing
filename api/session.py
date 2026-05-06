"""Session store — richer status enum + per-agent registry."""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional
from uuid import uuid4

from agent.loop import AgentEvent, TokenUsage


class SessionStatus(str, Enum):
    PENDING      = "pending"
    QUEUED       = "queued"
    RUNNING      = "running"
    DONE         = "done"
    ERROR        = "error"
    INTERRUPTED  = "interrupted"


@dataclass
class Session:
    id: str
    task: str
    agent_id: str          = field(default_factory=lambda: os.environ.get("AGENT_ID", "1"))
    created_at: float      = field(default_factory=time.time)
    status: SessionStatus  = SessionStatus.PENDING
    events: list[AgentEvent] = field(default_factory=list)
    usage: Optional[TokenUsage] = None
    error: Optional[str]   = None
    queue_position: int    = 0
    extracted_data: Optional[dict] = None   # structured data the agent extracted

    def append_event(self, event: AgentEvent) -> None:
        self.events.append(event)
        if event.type == "usage":
            self.usage = event.data
        elif event.type == "error":
            self.error = event.data
            self.status = SessionStatus.ERROR
        elif event.type == "done":
            self.status = SessionStatus.DONE


_sessions: dict[str, Session] = {}


def create_session(task: str) -> Session:
    s = Session(id=str(uuid4()), task=task)
    _sessions[s.id] = s
    return s


def get_session(session_id: str) -> Optional[Session]:
    return _sessions.get(session_id)


def all_sessions() -> list[Session]:
    return list(_sessions.values())
