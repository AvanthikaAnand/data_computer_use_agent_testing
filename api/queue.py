"""Per-agent FIFO task queue — one task runs at a time, others wait."""

from __future__ import annotations

import asyncio
from typing import Any, Callable, Coroutine, Optional

from .session import Session, SessionStatus


class AgentQueue:
    """FIFO queue that runs one session at a time, queuing the rest."""

    def __init__(self) -> None:
        self._queue: asyncio.Queue[Session] = asyncio.Queue()
        self.current: Optional[Session] = None
        self._runner: Optional[Callable[[Session], Coroutine[Any, Any, None]]] = None

    def start(self, runner: Callable[[Session], Coroutine[Any, Any, None]]) -> None:
        self._runner = runner
        asyncio.create_task(self._worker())

    async def submit(self, session: Session) -> int:
        """Enqueue a session. Returns queue position (0 = next up)."""
        pos = self._queue.qsize() + (1 if self.current else 0)
        session.queue_position = pos
        session.status = SessionStatus.QUEUED
        await self._queue.put(session)
        return pos

    def interrupt(self) -> bool:
        """Signal the current session to stop. Returns True if there was one."""
        if self.current:
            self.current.status = SessionStatus.INTERRUPTED
            return True
        return False

    @property
    def depth(self) -> int:
        return self._queue.qsize()

    @property
    def info(self) -> dict:
        return {
            "current": self.current.id if self.current else None,
            "current_task": self.current.task[:80] if self.current else None,
            "queued": self.depth,
        }

    async def _worker(self) -> None:
        assert self._runner
        while True:
            session = await self._queue.get()
            self.current = session
            session.status = SessionStatus.RUNNING
            try:
                await self._runner(session)
            except Exception as exc:
                session.error = str(exc)
                session.status = SessionStatus.ERROR
            finally:
                if session.status == SessionStatus.RUNNING:
                    session.status = SessionStatus.DONE
                self.current = None
                self._queue.task_done()


# Module-level singleton — shared across all requests on this agent
queue = AgentQueue()
