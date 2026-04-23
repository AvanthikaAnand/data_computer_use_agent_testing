"""Computer tool — screenshot, mouse, keyboard actions via xdotool + scrot."""

from __future__ import annotations

import asyncio
import base64
import os
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Literal

from agent.config import config

SCREENSHOT_PATH = "/tmp/cu_screenshot.png"


class Action(str, Enum):
    screenshot = "screenshot"
    left_click = "left_click"
    right_click = "right_click"
    middle_click = "middle_click"
    double_click = "double_click"
    left_click_drag = "left_click_drag"
    mouse_move = "mouse_move"
    type = "type"
    key = "key"
    scroll = "scroll"
    cursor_position = "cursor_position"
    wait = "wait"
    triple_click = "triple_click"


@dataclass
class ToolResult:
    output: str | None = None
    error: str | None = None
    base64_image: str | None = None

    @property
    def success(self) -> bool:
        return self.error is None


class ComputerTool:
    name = "computer"
    api_type: str  # set by tool group

    def __init__(self, display: str | None = None):
        self.display = display or config.desktop.display
        self.width = config.desktop.width
        self.height = config.desktop.height
        self._env = {**os.environ, "DISPLAY": self.display}

    def to_params(self) -> dict[str, Any]:
        return {
            "type": config.capabilities.computer_use_tool_version,
            "name": self.name,
            "display_width_px": self.width,
            "display_height_px": self.height,
            "display_number": int(self.display.lstrip(":")),
        }

    async def __call__(self, *, action: str, **kwargs: Any) -> ToolResult:
        act = Action(action)

        if act == Action.screenshot:
            return await self._screenshot()
        if act == Action.left_click:
            return await self._click(kwargs["coordinate"], button="left")
        if act == Action.right_click:
            return await self._click(kwargs["coordinate"], button="right")
        if act == Action.middle_click:
            return await self._click(kwargs["coordinate"], button="middle")
        if act == Action.double_click:
            return await self._click(kwargs["coordinate"], button="left", double=True)
        if act == Action.triple_click:
            coord = kwargs["coordinate"]
            await self._run(f"xdotool mousemove --sync {coord[0]} {coord[1]}")
            await self._run("xdotool click --repeat 3 1")
            return ToolResult(output="triple clicked")
        if act == Action.mouse_move:
            coord = kwargs["coordinate"]
            await self._run(f"xdotool mousemove --sync {coord[0]} {coord[1]}")
            return ToolResult(output=f"moved to {coord}")
        if act == Action.left_click_drag:
            return await self._drag(kwargs["start_coordinate"], kwargs["coordinate"])
        if act == Action.type:
            return await self._type(kwargs["text"])
        if act == Action.key:
            return await self._key(kwargs["key"])
        if act == Action.scroll:
            return await self._scroll(kwargs["coordinate"], kwargs.get("direction", "down"), kwargs.get("num_scrolls", 3))
        if act == Action.cursor_position:
            out = await self._run("xdotool getmouselocation --shell")
            return ToolResult(output=out)
        if act == Action.wait:
            await asyncio.sleep(kwargs.get("duration", 1))
            return ToolResult(output="waited")

        return ToolResult(error=f"Unknown action: {action}")

    async def _screenshot(self) -> ToolResult:
        await asyncio.sleep(config.screenshot_delay)
        err = await self._run(f"scrot -z {SCREENSHOT_PATH}")
        if not Path(SCREENSHOT_PATH).exists():
            return ToolResult(error=f"Screenshot failed: {err}")
        data = Path(SCREENSHOT_PATH).read_bytes()
        return ToolResult(base64_image=base64.standard_b64encode(data).decode())

    async def _click(self, coord: list[int], *, button: str, double: bool = False) -> ToolResult:
        btn_map = {"left": "1", "middle": "2", "right": "3"}
        btn = btn_map[button]
        await self._run(f"xdotool mousemove --sync {coord[0]} {coord[1]}")
        repeat = "--repeat 2 " if double else ""
        await self._run(f"xdotool click {repeat}{btn}")
        return ToolResult(output=f"{button}_click at {coord}")

    async def _drag(self, start: list[int], end: list[int]) -> ToolResult:
        await self._run(f"xdotool mousemove --sync {start[0]} {start[1]}")
        await self._run(f"xdotool mousedown 1")
        await self._run(f"xdotool mousemove --sync {end[0]} {end[1]}")
        await self._run(f"xdotool mouseup 1")
        return ToolResult(output=f"dragged {start} -> {end}")

    async def _type(self, text: str) -> ToolResult:
        delay = config.typing_delay_ms
        chunk = config.typing_chunk_size
        for i in range(0, len(text), chunk):
            part = text[i : i + chunk]
            escaped = part.replace("'", "'\\''")
            await self._run(f"xdotool type --delay {delay} -- '{escaped}'")
        return ToolResult(output=f"typed {len(text)} chars")

    async def _key(self, key: str) -> ToolResult:
        await self._run(f"xdotool key -- {key}")
        return ToolResult(output=f"key: {key}")

    async def _scroll(self, coord: list[int], direction: str, num: int) -> ToolResult:
        btn = "4" if direction == "up" else "5"
        await self._run(f"xdotool mousemove --sync {coord[0]} {coord[1]}")
        for _ in range(num):
            await self._run(f"xdotool click {btn}")
        return ToolResult(output=f"scrolled {direction} x{num}")

    async def _run(self, cmd: str) -> str:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            env=self._env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        return (stdout + stderr).decode().strip()
