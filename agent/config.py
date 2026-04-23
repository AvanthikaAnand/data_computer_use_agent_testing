"""Central configuration loader — reads config.yaml + environment overrides."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml

_ROOT = Path(__file__).parent.parent
_CONFIG_PATH = _ROOT / "config.yaml"


@dataclass
class DesktopConfig:
    display: str = ":1"
    width: int = 1366
    height: int = 768
    depth: int = 24
    vnc_port: int = 5901
    novnc_port: int = 6080


@dataclass
class ModelCapabilities:
    computer_use_tool_version: str = "computer_use_20250124"
    max_output_tokens: int = 16000
    supports_thinking: bool = True
    thinking_budget: int = 8000
    enable_prompt_caching: bool = True


@dataclass
class AgentConfig:
    # provider + model
    provider: str = "bedrock"
    active_model: str = "claude-sonnet-3-7"
    models: dict[str, str] = field(default_factory=dict)

    # provider-specific
    bedrock_region: str = "us-east-1"
    anthropic_api_key: Optional[str] = None
    anthropic_base_url: Optional[str] = None
    ollama_base_url: str = "http://localhost:11434"
    litellm_base_url: Optional[str] = None

    # agent behaviour
    max_turns: int = 50
    screenshot_delay: float = 0.5
    typing_delay_ms: int = 3
    typing_chunk_size: int = 50

    # model capabilities
    capabilities: ModelCapabilities = field(default_factory=ModelCapabilities)
    desktop: DesktopConfig = field(default_factory=DesktopConfig)

    # ui
    ui_port: int = 7860
    ui_share: bool = False
    ui_theme: str = "soft"

    def resolved_model_id(self) -> str:
        """Return the raw model ID for the active model (lookup or direct string)."""
        return self.models.get(self.active_model, self.active_model)


def load_config(path: Path = _CONFIG_PATH) -> AgentConfig:
    raw: dict = {}
    if path.exists():
        with open(path) as f:
            raw = yaml.safe_load(f) or {}

    caps_raw = raw.get("model_capabilities", {})
    desktop_raw = raw.get("desktop", {})
    ui_raw = raw.get("ui", {})
    agent_raw = raw.get("agent", {})
    bedrock_raw = raw.get("bedrock", {})
    anthropic_raw = raw.get("anthropic", {})
    ollama_raw = raw.get("ollama", {})
    litellm_raw = raw.get("litellm", {})

    cfg = AgentConfig(
        provider=os.environ.get("CU_PROVIDER", raw.get("provider", "bedrock")),
        active_model=os.environ.get("CU_MODEL", raw.get("active_model", "claude-sonnet-3-7")),
        models=raw.get("models", {}),
        bedrock_region=os.environ.get("AWS_DEFAULT_REGION", bedrock_raw.get("region", "us-east-1")),
        anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", anthropic_raw.get("api_key")),
        anthropic_base_url=anthropic_raw.get("base_url"),
        ollama_base_url=ollama_raw.get("base_url", "http://localhost:11434"),
        litellm_base_url=os.environ.get("LITELLM_API_BASE", litellm_raw.get("base_url")),
        max_turns=agent_raw.get("max_turns", 50),
        screenshot_delay=agent_raw.get("screenshot_delay", 0.5),
        typing_delay_ms=agent_raw.get("typing_delay_ms", 3),
        typing_chunk_size=agent_raw.get("typing_chunk_size", 50),
        capabilities=ModelCapabilities(
            computer_use_tool_version=caps_raw.get("computer_use_tool_version", "computer_use_20250124"),
            max_output_tokens=caps_raw.get("max_output_tokens", 16000),
            supports_thinking=caps_raw.get("supports_thinking", True),
            thinking_budget=caps_raw.get("thinking_budget", 8000),
            enable_prompt_caching=caps_raw.get("enable_prompt_caching", True),
        ),
        desktop=DesktopConfig(
            display=desktop_raw.get("display", ":1"),
            width=desktop_raw.get("width", 1366),
            height=desktop_raw.get("height", 768),
            depth=desktop_raw.get("depth", 24),
            vnc_port=desktop_raw.get("vnc_port", 5901),
            novnc_port=desktop_raw.get("novnc_port", 6080),
        ),
        ui_port=ui_raw.get("port", 7860),
        ui_share=ui_raw.get("share", False),
        ui_theme=ui_raw.get("theme", "soft"),
    )
    return cfg


# Module-level singleton — import this everywhere
config = load_config()
