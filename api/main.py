"""FastAPI — REST + SSE + WebSocket interface for the computer use agent.

Endpoints:
  POST  /task                    submit a task → {session_id, queue_position}
  GET   /task/{id}/stream        SSE stream of agent events
  GET   /task/{id}/status        snapshot: state + token usage
  POST  /task/{id}/interrupt     stop current task
  GET   /queue                   queue depth + current session
  GET   /health                  liveness probe (Traefik / ALB)
  GET   /metrics                 aggregate token & cost data for dashboard
  POST  /reset                   kill + restart the desktop environment
  WS    /ws                      WebSocket — real-time broadcast of all events
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any, AsyncGenerator, Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from agent.config import load_config
from agent.loop import AgentEvent, run_agent
from .queue import queue
from .session import Session, SessionStatus, all_sessions, create_session, get_session

AGENT_ID = os.environ.get("AGENT_ID", "1")

app = FastAPI(title=f"Computer Use Agent {AGENT_ID}", version="1.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


# ── WebSocket broadcast manager ───────────────────────────────────────────────

class _WSManager:
    def __init__(self) -> None:
        self._connections: set[WebSocket] = set()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self._connections.add(ws)

    def disconnect(self, ws: WebSocket) -> None:
        self._connections.discard(ws)

    async def broadcast(self, data: dict) -> None:
        dead: set[WebSocket] = set()
        for ws in self._connections:
            try:
                await ws.send_json(data)
            except Exception:
                dead.add(ws)
        self._connections -= dead

    @property
    def count(self) -> int:
        return len(self._connections)


ws_manager = _WSManager()


# ── Startup — wire queue runner ───────────────────────────────────────────────

@app.on_event("startup")
async def _startup() -> None:
    queue.start(_run_session)


# ── Session runner ────────────────────────────────────────────────────────────

async def _run_session(session: Session) -> None:
    cfg = load_config()

    await ws_manager.broadcast({"type": "session_start", "session_id": session.id,
                                 "task": session.task, "agent_id": AGENT_ID})

    async for event in run_agent(session.task, cfg=cfg):
        # Stop if interrupted
        if session.status == SessionStatus.INTERRUPTED:
            break

        session.append_event(event)

        await ws_manager.broadcast({
            "type": "event",
            "session_id": session.id,
            "agent_id": AGENT_ID,
            "event_type": event.type,
            "data": _serialise(event.data),
        })

    await ws_manager.broadcast({"type": "session_end", "session_id": session.id,
                                 "status": session.status, "agent_id": AGENT_ID})


# ── Helpers ───────────────────────────────────────────────────────────────────

def _serialise(data: Any) -> Any:
    if data is None:
        return None
    if hasattr(data, "__dict__"):
        return data.__dict__
    return data


async def _sse_generator(session: Session) -> AsyncGenerator[str, None]:
    cursor = 0
    while True:
        while cursor < len(session.events):
            yield f"data: {json.dumps({'type': session.events[cursor].type, 'data': _serialise(session.events[cursor].data)})}\n\n"
            cursor += 1
        if session.status in (SessionStatus.DONE, SessionStatus.ERROR, SessionStatus.INTERRUPTED):
            break
        await asyncio.sleep(0.1)
    yield 'data: {"type": "stream_end"}\n\n'


def _usage_dict(s: Session) -> Optional[dict]:
    if not s.usage:
        return None
    u = s.usage
    return {"input_tokens": u.input, "output_tokens": u.output,
            "cache_read": u.cache_read, "cache_write": u.cache_write}


# ── Request / Response models ─────────────────────────────────────────────────

class TaskRequest(BaseModel):
    task: str
    provider: Optional[str] = None
    model: Optional[str] = None
    max_turns: Optional[int] = None
    thinking_budget: Optional[int] = None
    return_extracted_data: bool = False


class TaskResponse(BaseModel):
    session_id: str
    status: str
    queue_position: int
    agent_id: str


# ── Routes ────────────────────────────────────────────────────────────────────

@app.post("/task", response_model=TaskResponse, status_code=202)
async def submit_task(req: TaskRequest) -> TaskResponse:
    session = create_session(req.task)
    pos = await queue.submit(session)
    return TaskResponse(session_id=session.id, status=session.status,
                        queue_position=pos, agent_id=AGENT_ID)


@app.get("/task/{session_id}/stream")
async def stream_task(session_id: str) -> StreamingResponse:
    session = get_session(session_id)
    if not session:
        raise HTTPException(404, "Session not found")
    return StreamingResponse(_sse_generator(session), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.get("/task/{session_id}/status")
async def task_status(session_id: str) -> dict:
    s = get_session(session_id)
    if not s:
        raise HTTPException(404, "Session not found")
    return {"session_id": s.id, "task": s.task, "status": s.status,
            "agent_id": s.agent_id, "queue_position": s.queue_position,
            "event_count": len(s.events), "error": s.error,
            "created_at": s.created_at, "usage": _usage_dict(s),
            "extracted_data": s.extracted_data}


@app.post("/task/{session_id}/interrupt")
async def interrupt_task(session_id: str) -> dict:
    s = get_session(session_id)
    if not s:
        raise HTTPException(404, "Session not found")
    if queue.current and queue.current.id == session_id:
        queue.interrupt()
        return {"interrupted": True}
    return {"interrupted": False, "reason": "not current task"}


@app.get("/queue")
async def queue_info() -> dict:
    return {"agent_id": AGENT_ID, **queue.info}


@app.get("/health")
async def health() -> dict:
    sessions = all_sessions()
    return {
        "status": "ok",
        "agent_id": AGENT_ID,
        "queue": queue.info,
        "ws_connections": ws_manager.count,
        "sessions": {
            "running": sum(1 for s in sessions if s.status == SessionStatus.RUNNING),
            "total": len(sessions),
        },
    }


@app.get("/metrics")
async def metrics() -> dict:
    sessions = all_sessions()
    by_status: dict[str, int] = {}
    for s in sessions:
        by_status[s.status] = by_status.get(s.status, 0) + 1

    return {
        "agent_id": AGENT_ID,
        "queue": queue.info,
        "sessions": {**by_status, "total": len(sessions)},
        "tokens": {
            "total_input":       sum(s.usage.input       for s in sessions if s.usage),
            "total_output":      sum(s.usage.output      for s in sessions if s.usage),
            "total_cache_read":  sum(s.usage.cache_read  for s in sessions if s.usage),
            "total_cache_write": sum(s.usage.cache_write for s in sessions if s.usage),
        },
        "recent_sessions": [
            {"id": s.id, "task": s.task[:100], "status": s.status,
             "created_at": s.created_at, "usage": _usage_dict(s)}
            for s in sorted(sessions, key=lambda x: x.created_at, reverse=True)[:20]
        ],
    }


@app.post("/reset")
async def reset_desktop() -> dict:
    """Kill and restart the XFCE4 desktop — clears any stuck state."""
    proc = await asyncio.create_subprocess_shell(
        "pkill -f xfce4 || true; sleep 1; startxfce4 &",
        env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":1")},
    )
    await proc.wait()
    return {"reset": True, "agent_id": AGENT_ID}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket) -> None:
    """Real-time event stream — dashboard connects here."""
    await ws_manager.connect(ws)
    try:
        # Send current state immediately on connect
        await ws.send_json({"type": "connected", "agent_id": AGENT_ID, **queue.info})
        while True:
            await ws.receive_text()   # keep-alive ping/pong
    except WebSocketDisconnect:
        ws_manager.disconnect(ws)
