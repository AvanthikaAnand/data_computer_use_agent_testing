"""File edit tool for the agent — view, create, str_replace, insert."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal


@dataclass
class ToolResult:
    output: str | None = None
    error: str | None = None


class EditTool:
    name = "str_replace_editor"
    _history: dict[Path, list[str]]

    def __init__(self):
        self._history = {}

    def to_params(self) -> dict:
        return {
            "type": "custom",
            "name": self.name,
            "description": "View, create, or edit files using str_replace or insert.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "enum": ["view", "create", "str_replace", "insert", "undo_edit"]},
                    "path": {"type": "string"},
                    "file_text": {"type": "string"},
                    "old_str": {"type": "string"},
                    "new_str": {"type": "string"},
                    "insert_line": {"type": "integer"},
                    "new_str_insert": {"type": "string"},
                },
                "required": ["command", "path"],
            },
        }

    async def __call__(self, *, command: str, path: str, **kwargs) -> ToolResult:
        p = Path(path)
        if not p.is_absolute():
            return ToolResult(error="Path must be absolute")

        if command == "view":
            if not p.exists():
                return ToolResult(error=f"File not found: {p}")
            lines = p.read_text().splitlines()
            numbered = "\n".join(f"{i+1:4d} | {l}" for i, l in enumerate(lines))
            return ToolResult(output=numbered)

        if command == "create":
            p.parent.mkdir(parents=True, exist_ok=True)
            content = kwargs.get("file_text", "")
            self._save_history(p)
            p.write_text(content)
            return ToolResult(output=f"Created {p}")

        if command == "str_replace":
            if not p.exists():
                return ToolResult(error=f"File not found: {p}")
            old_str = kwargs.get("old_str", "")
            new_str = kwargs.get("new_str", "")
            text = p.read_text()
            if old_str not in text:
                return ToolResult(error="old_str not found in file")
            self._save_history(p)
            p.write_text(text.replace(old_str, new_str, 1))
            return ToolResult(output="Replaced successfully")

        if command == "insert":
            if not p.exists():
                return ToolResult(error=f"File not found: {p}")
            lines = p.read_text().splitlines(keepends=True)
            line_num = kwargs.get("insert_line", 0)
            new_lines = kwargs.get("new_str_insert", "").splitlines(keepends=True)
            self._save_history(p)
            lines[line_num:line_num] = new_lines
            p.write_text("".join(lines))
            return ToolResult(output=f"Inserted {len(new_lines)} lines at {line_num}")

        if command == "undo_edit":
            if p not in self._history or not self._history[p]:
                return ToolResult(error="No history to undo")
            p.write_text(self._history[p].pop())
            return ToolResult(output="Undone")

        return ToolResult(error=f"Unknown command: {command}")

    def _save_history(self, p: Path) -> None:
        if p not in self._history:
            self._history[p] = []
        if p.exists():
            self._history[p].append(p.read_text())
