"""Provider factory — returns the right LLMProvider for a given config."""

from __future__ import annotations

from agent.config import AgentConfig
from .base import LLMProvider, ProviderType


def create_provider(cfg: AgentConfig) -> LLMProvider:
    provider = ProviderType(cfg.provider)

    if provider == ProviderType.BEDROCK:
        from .bedrock import BedrockProvider
        return BedrockProvider(region=cfg.bedrock_region)

    if provider == ProviderType.ANTHROPIC:
        from .anthropic_provider import AnthropicProvider
        return AnthropicProvider(api_key=cfg.anthropic_api_key, base_url=cfg.anthropic_base_url)

    if provider == ProviderType.OLLAMA:
        from .ollama import OllamaProvider
        return OllamaProvider(base_url=cfg.ollama_base_url)

    if provider == ProviderType.LITELLM:
        from .litellm_provider import LiteLLMProvider
        return LiteLLMProvider(base_url=cfg.litellm_base_url)

    raise ValueError(f"Unknown provider: {cfg.provider}")
