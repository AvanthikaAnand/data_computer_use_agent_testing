"""Multi-agent monitoring dashboard — connects to all agent APIs."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import gradio as gr
import httpx

sys.path.insert(0, str(Path(__file__).parent.parent))

# Agent URLs injected via AGENT_URLS env var (comma-separated)
# e.g. "http://cu-agent-1:8000,http://cu-agent-2:8000,..."
_AGENT_URLS: list[str] = [
    u.strip() for u in os.environ.get("AGENT_URLS", "http://cu-agent-1:8000").split(",") if u.strip()
]
_VNC_BASE_PORTS  = [int(p) for p in os.environ.get("VNC_PORTS",  "6081,6082,6083,6084,6085").split(",")]
_UI_BASE_PORTS   = [int(p) for p in os.environ.get("UI_PORTS",   "7861,7862,7863,7864,7865").split(",")]
_HOST            = os.environ.get("AGENT_HOST", "localhost")


def _fetch(url: str, timeout: float = 3.0) -> dict:
    try:
        r = httpx.get(url, timeout=timeout)
        return r.json()
    except Exception as e:
        return {"error": str(e)}


def _status_icon(status: str) -> str:
    return {"running": "🟢", "queued": "🟡", "done": "✅", "error": "🔴",
            "idle": "⚪", "pending": "⚪", "interrupted": "🔶"}.get(status, "⚪")


def _agent_rows() -> list[list]:
    rows = []
    for i, url in enumerate(_AGENT_URLS):
        agent_num = i + 1
        h = _fetch(f"{url}/health")
        m = _fetch(f"{url}/metrics")

        if "error" in h:
            rows.append([f"Agent {agent_num}", "🔴 Unreachable", "—", "—", "—", "—", "—", "—"])
            continue

        queue = h.get("queue", {})
        current_task = (queue.get("current_task") or "idle")[:50]
        queue_depth  = queue.get("queued", 0)
        sessions     = m.get("sessions", {})
        tokens       = m.get("tokens", {})
        status       = "running" if queue.get("current") else "idle"

        vnc_port = _VNC_BASE_PORTS[i] if i < len(_VNC_BASE_PORTS) else 6081 + i
        ui_port  = _UI_BASE_PORTS[i]  if i < len(_UI_BASE_PORTS)  else 7861 + i

        rows.append([
            f"Agent {agent_num}",
            f"{_status_icon(status)} {status}",
            current_task,
            str(queue_depth),
            str(sessions.get("total", 0)),
            f"{tokens.get('total_input', 0):,}",
            f"[Desktop](http://{_HOST}:{vnc_port})",
            f"[UI](http://{_HOST}:{ui_port})",
        ])
    return rows


def _aggregate_metrics() -> str:
    total_sessions = total_input = total_output = total_cache = running = 0
    for url in _AGENT_URLS:
        m = _fetch(f"{url}/metrics")
        if "error" in m:
            continue
        s = m.get("sessions", {})
        t = m.get("tokens", {})
        total_sessions += s.get("total", 0)
        running        += s.get("running", 0)
        total_input    += t.get("total_input", 0)
        total_output   += t.get("total_output", 0)
        total_cache    += t.get("total_cache_read", 0)

    return (
        f"**Agents:** {len(_AGENT_URLS)} | "
        f"**Running:** {running} | "
        f"**Total sessions:** {total_sessions} | "
        f"**Input tokens:** {total_input:,} | "
        f"**Output tokens:** {total_output:,} | "
        f"**Cache hits:** {total_cache:,}"
    )


def _recent_sessions(limit: int = 30) -> list[list]:
    all_sessions = []
    for i, url in enumerate(_AGENT_URLS):
        m = _fetch(f"{url}/metrics")
        for s in m.get("recent_sessions", []):
            usage = s.get("usage") or {}
            all_sessions.append([
                f"Agent {i+1}",
                s.get("status", ""),
                s.get("task", "")[:60],
                str(usage.get("input_tokens", 0)),
                str(usage.get("output_tokens", 0)),
                s.get("id", "")[:8],
            ])
    all_sessions.sort(key=lambda r: r[5], reverse=True)
    return all_sessions[:limit]


def refresh():
    return (
        _agent_rows(),
        _aggregate_metrics(),
        _recent_sessions(),
    )


def build_dashboard() -> gr.Blocks:
    with gr.Blocks(title="CU Agent Dashboard") as app:
        gr.Markdown("# 🖥️ Computer Use Agent — Multi-Agent Dashboard")

        summary = gr.Markdown(_aggregate_metrics())

        gr.Markdown("## Agent Status")
        agent_table = gr.Dataframe(
            headers=["Agent", "Status", "Current Task", "Queued", "Total Sessions",
                     "Input Tokens", "Desktop", "UI"],
            value=_agent_rows(),
            interactive=False,
            wrap=True,
        )

        gr.Markdown("## Recent Sessions")
        session_table = gr.Dataframe(
            headers=["Agent", "Status", "Task", "Input Tokens", "Output Tokens", "Session ID"],
            value=_recent_sessions(),
            interactive=False,
            wrap=True,
        )

        refresh_btn = gr.Button("🔄 Refresh", variant="secondary")
        refresh_btn.click(fn=refresh, outputs=[agent_table, summary, session_table])

        # Auto-refresh every 10 seconds
        app.load(fn=refresh, outputs=[agent_table, summary, session_table], every=10)

    return app


def main():
    port = int(os.environ.get("DASHBOARD_PORT", "8503"))
    build_dashboard().launch(server_name="0.0.0.0", server_port=port)


if __name__ == "__main__":
    main()
