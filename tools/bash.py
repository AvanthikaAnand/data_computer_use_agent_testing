"""Bash tool — persistent shell session for the agent."""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass

TIMEOUT = 120
SENTINEL = "<<<CU_BASH_DONE>>>"
MAX_OUTPUT_LEN = 16_000
TRUNCATED_NOTICE = "\n<response clipped — output exceeded 16 000 chars. Use grep or redirect to a file to read large outputs.>"


def _maybe_truncate(text: str) -> str:
    if len(text) <= MAX_OUTPUT_LEN:
        return text
    return text[:MAX_OUTPUT_LEN] + TRUNCATED_NOTICE


@dataclass
class ToolResult:
    output: str | None = None
    error: str | None = None


class BashTool:
    name = "bash"

    def __init__(self):
        self._process: asyncio.subprocess.Process | None = None

    def to_params(self) -> dict:
        return {
            "type": "custom",
            "name": self.name,
            "description": "Run a bash command in a persistent shell session.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Bash command to run"},
                    "restart": {"type": "boolean", "description": "Restart the shell session"},
                },
                "required": ["command"],
            },
        }

    async def __call__(self, *, command: str | None = None, restart: bool = False) -> ToolResult:
        if restart or self._process is None:
            await self._start()
            if restart:
                return ToolResult(output="Shell restarted.")

        assert self._process and self._process.stdin and self._process.stdout

        cmd = f"{command}; echo '{SENTINEL}'\n"
        self._process.stdin.write(cmd.encode())
        await self._process.stdin.drain()

        output_parts: list[str] = []
        try:
            async with asyncio.timeout(TIMEOUT):
                while True:
                    line = await self._process.stdout.readline()
                    decoded = line.decode()
                    if SENTINEL in decoded:
                        break
                    output_parts.append(decoded)
        except asyncio.TimeoutError:
            return ToolResult(error=f"Command timed out after {TIMEOUT}s")

        raw = "".join(output_parts).strip() or "(no output)"
        return ToolResult(output=_maybe_truncate(raw))

    async def _start(self) -> None:
        if self._process:
            try:
                self._process.kill()
            except Exception:
                pass
        self._process = await asyncio.create_subprocess_exec(
            "/bin/bash",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=os.environ,
        )
