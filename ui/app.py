"""Gradio UI — chat interface + model configuration panel."""

from __future__ import annotations

import asyncio
import copy
import sys
from pathlib import Path
from typing import Generator

import gradio as gr

sys.path.insert(0, str(Path(__file__).parent.parent))

from agent.config import AgentConfig, ModelCapabilities, DesktopConfig, load_config
from agent.loop import run_agent, AgentEvent
from agent.providers import create_provider

# ── helpers ──────────────────────────────────────────────────────────────────

PROVIDER_OPTIONS = ["bedrock", "anthropic", "ollama", "litellm"]

PRESET_MODELS = {
    "bedrock": [
        "us.anthropic.claude-sonnet-4-5-20251001-v1:0",
        "us.anthropic.claude-3-7-sonnet-20250219-v1:0",
        "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        "us.anthropic.claude-haiku-3-5-20241022-v1:0",
        "us.meta.llama3-2-90b-instruct-v1:0",
        "us.meta.llama3-3-70b-instruct-v1:0",
    ],
    "anthropic": [
        "claude-sonnet-4-5-20251001",
        "claude-3-7-sonnet-20250219",
        "claude-3-5-sonnet-20241022",
        "claude-haiku-3-5-20241022",
    ],
    "ollama": [
        "ollama/llava",
        "ollama/llama3.2-vision",
        "ollama/qwen2.5vl",
        "ollama/minicpm-v",
    ],
    "litellm": [
        "bedrock/us.anthropic.claude-sonnet-4-5-20251001-v1:0",
        "anthropic/claude-sonnet-4-5-20251001",
        "ollama/llava",
        "openai/gpt-4o",
    ],
}

TOOL_VERSIONS = [
    "computer_use_20250124",
    "computer_use_20241022",
    "computer_use_20250429",
]


def build_config(
    provider: str,
    model_id: str,
    custom_model: str,
    region: str,
    anthropic_key: str,
    ollama_url: str,
    max_turns: int,
    max_tokens: int,
    tool_version: str,
    enable_thinking: bool,
    thinking_budget: int,
    screenshot_delay: float,
    typing_delay: int,
) -> AgentConfig:
    cfg = load_config()
    cfg.provider = provider
    cfg.active_model = custom_model.strip() if custom_model.strip() else model_id
    cfg.bedrock_region = region
    cfg.anthropic_api_key = anthropic_key or None
    cfg.ollama_base_url = ollama_url
    cfg.max_turns = max_turns
    cfg.screenshot_delay = screenshot_delay
    cfg.typing_delay_ms = typing_delay
    cfg.capabilities = ModelCapabilities(
        computer_use_tool_version=tool_version,
        max_output_tokens=max_tokens,
        supports_thinking=enable_thinking,
        thinking_budget=thinking_budget if enable_thinking else 0,
        enable_prompt_caching=True,
    )
    return cfg


def update_model_dropdown(provider: str):
    choices = PRESET_MODELS.get(provider, [])
    value = choices[0] if choices else ""
    return gr.Dropdown(choices=choices, value=value)


def run_task_sync(task: str, history: list, *cfg_args) -> Generator:
    """Sync wrapper around the async agent loop for Gradio."""
    if not task.strip():
        yield history, "", ""
        return

    cfg = build_config(*cfg_args)
    history = history + [[task, ""]]
    status = "Running..."

    async def collect():
        events = []
        async for event in run_agent(task, cfg=cfg):
            events.append(event)
        return events

    loop = asyncio.new_event_loop()
    try:
        events: list[AgentEvent] = loop.run_until_complete(collect())
    finally:
        loop.close()

    response_parts: list[str] = []
    tool_log: list[str] = []
    usage_str = ""

    for ev in events:
        if ev.type == "text":
            response_parts.append(ev.data)
        elif ev.type == "tool_use":
            name = ev.data["name"]
            inp = ev.data["input"]
            tool_log.append(f"**[tool: {name}]** `{inp}`")
        elif ev.type == "tool_result" and ev.data.get("is_error"):
            tool_log.append(f"  ↳ error")
        elif ev.type == "usage":
            u = ev.data
            usage_str = (
                f"Tokens — in: {u.input}, out: {u.output}, "
                f"cache_read: {u.cache_read}, cache_write: {u.cache_write}"
            )
        elif ev.type == "error":
            response_parts.append(f"\n**Error:** {ev.data}")

    reply = "\n".join(response_parts)
    if tool_log:
        reply += "\n\n---\n" + "\n".join(tool_log)

    history[-1][1] = reply
    yield history, usage_str, ""


# ── layout ───────────────────────────────────────────────────────────────────

def build_ui() -> gr.Blocks:
    cfg = load_config()

    with gr.Blocks(title="Computer Use Agent", theme=gr.themes.Soft()) as app:
        gr.Markdown("# Computer Use Agent")
        gr.Markdown("Configure the LLM backend in the **Settings** tab, then chat in **Agent**.")

        with gr.Tabs():
            # ── Agent tab ──
            with gr.Tab("Agent"):
                chatbot = gr.Chatbot(height=500, label="Agent conversation")
                with gr.Row():
                    task_input = gr.Textbox(
                        placeholder="Describe a task for the agent...",
                        show_label=False,
                        scale=9,
                    )
                    send_btn = gr.Button("Run", variant="primary", scale=1)
                usage_display = gr.Markdown("")
                clear_btn = gr.Button("Clear conversation")

            # ── Settings tab ──
            with gr.Tab("Settings"):
                gr.Markdown("## LLM Backend")
                with gr.Row():
                    provider_dd = gr.Dropdown(
                        choices=PROVIDER_OPTIONS,
                        value=cfg.provider,
                        label="Provider",
                        scale=1,
                    )
                    model_dd = gr.Dropdown(
                        choices=PRESET_MODELS.get(cfg.provider, []),
                        value=cfg.resolved_model_id(),
                        label="Model preset",
                        scale=2,
                    )
                custom_model = gr.Textbox(
                    label="Custom model ID (overrides preset if set)",
                    placeholder="e.g. us.meta.llama3-2-90b-instruct-v1:0",
                    value="",
                )

                gr.Markdown("## Provider Credentials")
                with gr.Row():
                    region_input = gr.Textbox(label="AWS Region (Bedrock)", value=cfg.bedrock_region, scale=1)
                    anthropic_key = gr.Textbox(label="Anthropic API Key", type="password", placeholder="sk-ant-...", scale=2)
                ollama_url = gr.Textbox(label="Ollama base URL", value=cfg.ollama_base_url)

                gr.Markdown("## Model Parameters")
                with gr.Row():
                    max_turns = gr.Slider(1, 100, value=cfg.max_turns, step=1, label="Max turns")
                    max_tokens = gr.Slider(1000, 128000, value=cfg.capabilities.max_output_tokens, step=1000, label="Max output tokens")
                tool_version_dd = gr.Dropdown(
                    choices=TOOL_VERSIONS,
                    value=cfg.capabilities.computer_use_tool_version,
                    label="Computer use tool version",
                )

                gr.Markdown("## Extended Thinking")
                with gr.Row():
                    enable_thinking = gr.Checkbox(
                        value=cfg.capabilities.supports_thinking,
                        label="Enable extended thinking",
                    )
                    thinking_budget = gr.Slider(
                        1000, 64000, value=cfg.capabilities.thinking_budget, step=1000,
                        label="Thinking token budget",
                    )

                gr.Markdown("## Performance")
                with gr.Row():
                    screenshot_delay = gr.Slider(0.1, 3.0, value=cfg.screenshot_delay, step=0.1, label="Screenshot delay (s)")
                    typing_delay = gr.Slider(1, 50, value=cfg.typing_delay_ms, step=1, label="Typing delay (ms/char)")

        # ── wire up events ──
        provider_dd.change(fn=update_model_dropdown, inputs=provider_dd, outputs=model_dd)

        cfg_inputs = [
            provider_dd, model_dd, custom_model,
            region_input, anthropic_key, ollama_url,
            max_turns, max_tokens, tool_version_dd,
            enable_thinking, thinking_budget,
            screenshot_delay, typing_delay,
        ]

        send_btn.click(
            fn=run_task_sync,
            inputs=[task_input, chatbot] + cfg_inputs,
            outputs=[chatbot, usage_display, task_input],
        )
        task_input.submit(
            fn=run_task_sync,
            inputs=[task_input, chatbot] + cfg_inputs,
            outputs=[chatbot, usage_display, task_input],
        )
        clear_btn.click(fn=lambda: ([], ""), outputs=[chatbot, usage_display])

    return app


def main():
    cfg = load_config()
    app = build_ui()
    app.launch(server_port=cfg.ui_port, share=cfg.ui_share)


if __name__ == "__main__":
    main()
