"""Direct Anthropic API provider."""

from __future__ import annotations

from typing import Any, Optional

from anthropic import Anthropic

from .base import LLMProvider


class AnthropicProvider(LLMProvider):
    def __init__(self, api_key: Optional[str] = None, base_url: Optional[str] = None):
        self._client = Anthropic(api_key=api_key, base_url=base_url, max_retries=4)

    @property
    def supports_computer_use_beta(self) -> bool:
        return True

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
        kwargs: dict[str, Any] = dict(
            model=model,
            max_tokens=max_tokens,
            messages=messages,
            system=[{"type": "text", "text": system}],
            tools=tools,
            betas=betas,
        )
        if extra_body:
            kwargs["extra_body"] = extra_body

        return self._client.beta.messages.with_raw_response.create(**kwargs)
