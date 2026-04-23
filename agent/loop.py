"""Main agentic sampling loop."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncGenerator
from dataclasses import dataclass, field
from typing import Any

from agent.config import AgentConfig, config as default_config
from agent.providers import LLMProvider, create_provider
from tools.bash import BashTool
from tools.computer import ComputerTool
from tools.edit import EditTool

SYSTEM_PROMPT = """You are a computer use agent operating a Linux desktop. You can:
- Take screenshots and interact with the GUI (click, type, drag, scroll)
- Run bash commands
- Read and edit files

Always take a screenshot first to understand the current state. Prefer keyboard shortcuts for speed.
When browsing, use Chrome (google-chrome). For file management, use Thunar.
Complete tasks efficiently and confirm each step visually before proceeding."""


@dataclass
class TokenUsage:
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0

    def add(self, response: Any) -> None:
        if hasattr(response, "usage"):
            u = response.usage
            self.input += getattr(u, "input_tokens", 0)
            self.output += getattr(u, "output_tokens", 0)
            self.cache_read += getattr(u, "cache_read_input_tokens", 0)
            self.cache_write += getattr(u, "cache_creation_input_tokens", 0)


@dataclass
class AgentEvent:
    type: str  # "text" | "tool_use" | "tool_result" | "usage" | "done" | "error"
    data: Any = None


# ── Prompt caching helpers ────────────────────────────────────────────────────

def _inject_prompt_caching(messages: list[dict]) -> None:
    """Set ephemeral cache breakpoints on the 3 most recent user turns.

    One cache slot is reserved for tools/system prompt (shared across sessions).
    Removing old breakpoints avoids stale cache entries accumulating.
    """
    breakpoints_remaining = 3
    for message in reversed(messages):
        if message["role"] == "user" and isinstance(message.get("content"), list):
            content = message["content"]
            if breakpoints_remaining:
                breakpoints_remaining -= 1
                content[-1]["cache_control"] = {"type": "ephemeral"}
            else:
                content[-1].pop("cache_control", None)
                break


# ── Image truncation ──────────────────────────────────────────────────────────

def _filter_to_n_most_recent_images(
    messages: list[dict],
    images_to_keep: int,
    min_removal_threshold: int = 10,
) -> None:
    """Drop old screenshots from tool_result blocks, keeping only the N most recent.

    Removes in chunks of min_removal_threshold to avoid unnecessarily breaking
    the implicit prompt cache on every single turn.
    """
    tool_results = [
        item
        for msg in messages
        for item in (msg["content"] if isinstance(msg.get("content"), list) else [])
        if isinstance(item, dict) and item.get("type") == "tool_result"
    ]

    total_images = sum(
        1
        for tr in tool_results
        for block in tr.get("content", [])
        if isinstance(block, dict) and block.get("type") == "image"
    )

    to_remove = total_images - images_to_keep
    # Round down to chunk boundary so cache breakpoints stay stable
    to_remove -= to_remove % min_removal_threshold

    for tr in tool_results:
        if not isinstance(tr.get("content"), list):
            continue
        new_content = []
        for block in tr["content"]:
            if isinstance(block, dict) and block.get("type") == "image" and to_remove > 0:
                to_remove -= 1
                continue
            new_content.append(block)
        tr["content"] = new_content


# ── Response → message params ─────────────────────────────────────────────────

def _response_to_params(response: Any) -> list[dict]:
    """Convert API response content blocks to message dict format.

    Preserves thinking block signatures — required by the API in subsequent
    turns; dropping them causes an API validation error.
    """
    result = []
    for block in response.content:
        block_type = getattr(block, "type", None)
        if block_type == "text":
            if block.text:
                result.append({"type": "text", "text": block.text})
        elif block_type == "thinking":
            thinking_block: dict = {
                "type": "thinking",
                "thinking": getattr(block, "thinking", None),
            }
            if hasattr(block, "signature"):
                thinking_block["signature"] = block.signature
            result.append(thinking_block)
        elif block_type == "tool_use":
            result.append({
                "type": "tool_use",
                "id": block.id,
                "name": block.name,
                "input": block.input,
            })
    return result


# ── Main loop ─────────────────────────────────────────────────────────────────

async def run_agent(
    task: str,
    cfg: AgentConfig | None = None,
    provider: LLMProvider | None = None,
) -> AsyncGenerator[AgentEvent, None]:
    """Run the agent loop, yielding events for the UI to consume."""
    cfg = cfg or default_config
    provider = provider or create_provider(cfg)

    computer = ComputerTool(display=cfg.desktop.display)
    bash = BashTool()
    edit = EditTool()

    tool_map = {
        computer.name: computer,
        bash.name: bash,
        edit.name: edit,
    }

    caps = cfg.capabilities
    betas: list[str] = [caps.computer_use_tool_version]
    if caps.enable_prompt_caching:
        betas.append("prompt-caching-2024-07-31")

    # System prompt with cache control so it's cached across sessions
    system_block: dict = {"type": "text", "text": SYSTEM_PROMPT}
    if caps.enable_prompt_caching:
        system_block["cache_control"] = {"type": "ephemeral"}

    tools = [computer.to_params(), bash.to_params(), edit.to_params()]
    model_id = cfg.resolved_model_id()

    messages: list[dict] = [{"role": "user", "content": task}]
    usage = TokenUsage()

    for turn in range(cfg.max_turns):
        # Inject cache breakpoints on the 3 most recent user turns
        if caps.enable_prompt_caching:
            _inject_prompt_caching(messages)

        # Drop old screenshots to avoid token blow-up on long tasks
        if cfg.only_n_most_recent_images:
            _filter_to_n_most_recent_images(messages, cfg.only_n_most_recent_images)

        extra_body: dict | None = None
        if caps.supports_thinking and caps.thinking_budget > 0:
            extra_body = {"thinking": {"type": "enabled", "budget_tokens": caps.thinking_budget}}

        try:
            raw = await provider.create_message(
                model=model_id,
                messages=messages,
                system=SYSTEM_PROMPT,
                tools=tools,
                max_tokens=caps.max_output_tokens,
                betas=betas,
                extra_body=extra_body,
            )
        except Exception as exc:
            yield AgentEvent(type="error", data=str(exc))
            return

        response = raw.parse() if hasattr(raw, "parse") else raw
        usage.add(response)

        # Convert response to storable params (preserves thinking signatures)
        assistant_params = _response_to_params(response)
        messages.append({"role": "assistant", "content": assistant_params})

        # Emit events for UI
        tool_uses = []
        for block in assistant_params:
            if block["type"] == "text":
                yield AgentEvent(type="text", data=block["text"])
            elif block["type"] == "tool_use":
                tool_uses.append(block)
                yield AgentEvent(type="tool_use", data={"name": block["name"], "input": block["input"]})

        if response.stop_reason == "end_turn" and not tool_uses:
            yield AgentEvent(type="usage", data=usage)
            yield AgentEvent(type="done")
            return

        # Execute tools and collect results
        tool_results: list[dict] = []
        for tool_use in tool_uses:
            tool = tool_map.get(tool_use["name"])
            if tool is None:
                result_content = [{"type": "text", "text": f"Unknown tool: {tool_use['name']}"}]
                is_error = True
            else:
                try:
                    result = await tool(**tool_use["input"])
                    is_error = bool(result.error)
                    parts: list[dict] = []
                    if result.output:
                        parts.append({"type": "text", "text": result.output})
                    if result.base64_image:
                        parts.append({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": result.base64_image}})
                    if result.error:
                        parts.append({"type": "text", "text": f"Error: {result.error}"})
                    result_content = parts or [{"type": "text", "text": "(no output)"}]
                except Exception as exc:
                    result_content = [{"type": "text", "text": str(exc)}]
                    is_error = True

            yield AgentEvent(type="tool_result", data={"name": tool_use["name"], "is_error": is_error})
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tool_use["id"],
                "content": result_content,
                "is_error": is_error,
            })

        messages.append({"role": "user", "content": tool_results})

    yield AgentEvent(type="error", data=f"Max turns ({cfg.max_turns}) reached without completion")
    yield AgentEvent(type="usage", data=usage)
