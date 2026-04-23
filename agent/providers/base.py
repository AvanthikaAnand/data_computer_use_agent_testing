"""Abstract LLM provider interface."""

from __future__ import annotations

from abc import ABC, abstractmethod
from enum import Enum
from typing import Any


class ProviderType(str, Enum):
    BEDROCK = "bedrock"
    ANTHROPIC = "anthropic"
    OLLAMA = "ollama"
    LITELLM = "litellm"


class LLMProvider(ABC):
    """All providers must implement this interface."""

    @abstractmethod
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
        """Send a message and return the raw API response object."""
        ...

    @property
    @abstractmethod
    def supports_computer_use_beta(self) -> bool:
        """Whether the provider accepts Anthropic beta flags for computer use."""
        ...
