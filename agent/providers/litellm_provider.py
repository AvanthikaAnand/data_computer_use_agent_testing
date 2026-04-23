"""LiteLLM universal provider — routes to any supported LLM with one interface.

Model ID examples (pass as active_model in config.yaml):
  bedrock/us.anthropic.claude-sonnet-4-5-20251001-v1:0
  anthropic/claude-sonnet-4-5-20251001
  ollama/llava
  openai/gpt-4o
  vertex_ai/claude-3-5-sonnet@20241022
"""

from __future__ import annotations

from typing import Any, Optional

import litellm

from .base import LLMProvider


class LiteLLMProvider(LLMProvider):
    """Thin wrapper around litellm.acompletion for maximum model flexibility."""

    def __init__(self, base_url: Optional[str] = None):
        self._base_url = base_url
        litellm.set_verbose = False
        # Drop unsupported params silently instead of erroring
        litellm.drop_params = True

    @property
    def supports_computer_use_beta(self) -> bool:
        return False  # Use generic tool calling, not Anthropic beta

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
        litellm_messages = [{"role": "system", "content": system}] + messages

        kwargs: dict[str, Any] = dict(
            model=model,
            messages=litellm_messages,
            max_tokens=max_tokens,
        )
        if self._base_url:
            kwargs["api_base"] = self._base_url
        if tools:
            kwargs["tools"] = _to_openai_tools(tools)
        if extra_body:
            kwargs.update(extra_body)

        return await litellm.acompletion(**kwargs)


def _to_openai_tools(anthropic_tools: list[dict]) -> list[dict]:
    result = []
    for t in anthropic_tools:
        if t.get("type", "").startswith("computer_"):
            continue
        result.append({
            "type": "function",
            "function": {
                "name": t["name"],
                "description": t.get("description", ""),
                "parameters": t.get("input_schema", {}),
            },
        })
    return result
