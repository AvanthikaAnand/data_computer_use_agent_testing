"""FastAPI — REST + SSE interface for the computer use agent.

Endpoints:
  POST  /task                    submit a task → {session_id}
  GET   /task/{id}/stream        SSE stream of agent events
  GET   /task/{id}/status        current state + token usage
  GET   /health                  liveness probe (used by Traefik + load balancer)
  GET   /metrics                 aggregate token & cost data for monitoring dashboard
"""

from __future__ import annotations

import asyncio
import json
from typing import Any, AsyncGenerator, Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from agent.config import load_config
from agent.loop import AgentEvent, run_agent
from .session import Session, all_sessions, create_session, get_session

app = FastAPI(title="Computer Use Agent", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Request / Response models ─────────────────────────────────────────────────

class TaskRequest(BaseModel):
    task: str
    provider: Optional[str] = None
    model: Optional[str] = None       # raw model ID or config.yaml key
    max_turns: Optional[int] = None
    thinking_budget: Optional[int] = None


class TaskResponse(BaseModel):
    session_id: str
    status: str


# ── Background runner ─────────────────────────────────────────────────────────

async def _run_session(session: Session, req: TaskRequest) -> None:
    cfg = load_config()
    if req.provider:
        cfg.provider = req.provider
    if req.model:
        cfg.active_model = req.model
    if req.max_turns:
        cfg.max_turns = req.max_turns
    if req.thinking_budget is not None:
        cfg.capabilities.thinking_budget = req.thinking_budget

    session.status = "running"
    try:
        async for event in run_agent(session.task, cfg=cfg):
            session.append_event(event)
    except Exception as exc:
        session.append_event(AgentEvent(type="error", data=str(exc)))
        session.status = "error"
    finally:
        if session.status == "running":
            session.status = "done"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _serialise_event(event: AgentEvent) -> str:
    """Convert an AgentEvent to a JSON-serialisable dict."""
    data: Any = event.data
    if hasattr(data, "__dict__"):           # e.g. TokenUsage dataclass
        data = data.__dict__
    return json.dumps({"type": event.type, "data": data})


async def _sse_generator(session: Session) -> AsyncGenerator[str, None]:
    """Replay existing events then tail new ones as SSE."""
    cursor = 0
    while True:
        while cursor < len(session.events):
            event = session.events[cursor]
            yield f"data: {_serialise_event(event)}\n\n"
            cursor += 1

        if session.status in ("done", "error"):
            break

        await asyncio.sleep(0.1)   # poll interval while agent is running

    yield "data: {\"type\": \"stream_end\"}\n\n"


# ── Routes ────────────────────────────────────────────────────────────────────

@app.post("/task", response_model=TaskResponse, status_code=202)
async def submit_task(req: TaskRequest, background_tasks: BackgroundTasks):
    """Submit a task. Returns immediately with a session_id to poll/stream."""
    session = create_session(req.task)
    background_tasks.add_task(_run_session, session, req)
    return TaskResponse(session_id=session.id, status=session.status)


@app.get("/task/{session_id}/stream")
async def stream_task(session_id: str):
    """Server-Sent Events stream of agent events for a session.
    Safe to call before the task has started — will block until events arrive.
    Multiple clients can connect to the same session_id concurrently.
    """
    session = get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    return StreamingResponse(
        _sse_generator(session),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",      # disable nginx buffering
        },
    )


@app.get("/task/{session_id}/status")
async def task_status(session_id: str):
    """Snapshot of session state — useful for polling without streaming."""
    session = get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    usage = None
    if session.usage:
        u = session.usage
        usage = {
            "input_tokens": u.input,
            "output_tokens": u.output,
            "cache_read_tokens": u.cache_read,
            "cache_write_tokens": u.cache_write,
        }

    return {
        "session_id": session.id,
        "task": session.task,
        "status": session.status,
        "event_count": len(session.events),
        "error": session.error,
        "created_at": session.created_at,
        "usage": usage,
    }


@app.get("/health")
async def health():
    """Liveness probe — Traefik and ALB health checks hit this."""
    sessions = all_sessions()
    return {
        "status": "ok",
        "sessions": {
            "running": sum(1 for s in sessions if s.status == "running"),
            "total": len(sessions),
        },
    }


@app.get("/metrics")
async def metrics():
    """Aggregate token usage and cost data — consumed by your monitoring dashboard."""
    sessions = all_sessions()

    by_status = {"pending": 0, "running": 0, "done": 0, "error": 0}
    for s in sessions:
        by_status[s.status] = by_status.get(s.status, 0) + 1

    total_input = sum(s.usage.input for s in sessions if s.usage)
    total_output = sum(s.usage.output for s in sessions if s.usage)
    total_cache_read = sum(s.usage.cache_read for s in sessions if s.usage)
    total_cache_write = sum(s.usage.cache_write for s in sessions if s.usage)

    return {
        "sessions": {**by_status, "total": len(sessions)},
        "tokens": {
            "total_input": total_input,
            "total_output": total_output,
            "total_cache_read": total_cache_read,
            "total_cache_write": total_cache_write,
        },
        "recent_sessions": [
            {
                "id": s.id,
                "task": s.task[:120],
                "status": s.status,
                "created_at": s.created_at,
                "usage": {
                    "input": s.usage.input,
                    "output": s.usage.output,
                    "cache_read": s.usage.cache_read,
                } if s.usage else None,
            }
            for s in sorted(sessions, key=lambda s: s.created_at, reverse=True)[:50]
        ],
    }
