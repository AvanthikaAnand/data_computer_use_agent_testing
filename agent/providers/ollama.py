"""Ollama provider for local open-source vision models via LiteLLM."""

from __future__ import annotations

from typing import Any

import litellm

from .base import LLMProvider


class OllamaProvider(LLMProvider):
    """Routes to Ollama via LiteLLM. Model IDs: 'ollama/llava', 'ollama/llama3.2-vision'."""

    def __init__(self, base_url: str = "http://localhost:11434"):
        self._base_url = base_url
        litellm.set_verbose = False

    @property
    def supports_computer_use_beta(self) -> bool:
        # Ollama models don't use Anthropic beta tool definitions
        return False

    async def create_message(
        self,
        *,
        model: str,
        messages: list[dict],
        system: str,
        tools: list[dict],
        max_tokens: int,
        betas: list[str],
        extra_body: dict | None = None,
    ) -> Any:
        # Prepend system as a system message for OpenAI-compatible format
        litellm_messages = [{"role": "system", "content": system}] + messages

        # Convert Anthropic tool format → OpenAI tool format for litellm
        openai_tools = _to_openai_tools(tools)

        response = await litellm.acompletion(
            model=model,
            messages=litellm_messages,
            tools=openai_tools if openai_tools else None,
            max_tokens=max_tokens,
            api_base=self._base_url,
        )
        return response


def _to_openai_tools(anthropic_tools: list[dict]) -> list[dict]:
    """Convert Anthropic tool schema to OpenAI function-calling schema."""
    result = []
    for t in anthropic_tools:
        if t.get("type") == "computer_20250124" or t.get("type", "").startswith("computer_"):
            continue  # Skip computer use tools — not supported by local models
        result.append({
            "type": "function",
            "function": {
                "name": t["name"],
                "description": t.get("description", ""),
                "parameters": t.get("input_schema", {}),
            },
        })
    return result
