"""外部工具管理预研接口。

本模块只定义外部工具源（例如未来 MCP stdio/http server）的后端边界，
不直接实现 MCP 协议，也不把外部工具注册进内置 ToolRegistry。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Protocol

from GensokyoAI.tools.errors import ToolError, ToolExecutionError


EXTERNAL_TOOL_PREFIX = "external"
_EXTERNAL_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
_EXTERNAL_TOOL_NAME_PATTERN = re.compile(r"^external__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+$")


class ExternalToolSourceStatus(str, Enum):
    """外部工具源生命周期状态。"""

    STARTING = "starting"
    RUNNING = "running"
    STOPPING = "stopping"
    STOPPED = "stopped"
    FAILED = "failed"
    RECONNECTING = "reconnecting"


@dataclass(frozen=True, slots=True)
class ExternalToolDefinition:
    """外部工具定义快照。

    namespaced_name 是注入模型与 Runtime 调用时使用的稳定名称，格式为
    ``external__server__tool``。source_id/tool_name 保留原始外部工具身份。
    """

    source_id: str
    tool_name: str
    namespaced_name: str
    description: str
    schema: dict[str, Any]
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_openai_schema(self) -> dict[str, Any]:
        schema = dict(self.schema)
        function = dict(schema.get("function") or {})
        function["name"] = self.namespaced_name
        if self.description and not function.get("description"):
            function["description"] = self.description
        schema["type"] = schema.get("type", "function")
        schema["function"] = function
        return schema

    def to_dict(self) -> dict[str, Any]:
        return {
            "source_id": self.source_id,
            "tool_name": self.tool_name,
            "namespaced_name": self.namespaced_name,
            "description": self.description,
            "schema": self.to_openai_schema(),
            "metadata": dict(self.metadata),
        }


@dataclass(slots=True)
class ExternalToolSourceState:
    """外部工具源状态快照。"""

    source_id: str
    status: ExternalToolSourceStatus = ExternalToolSourceStatus.STOPPED
    tools: list[ExternalToolDefinition] = field(default_factory=list)
    error: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self, *, include_tools: bool = True) -> dict[str, Any]:
        data: dict[str, Any] = {
            "source_id": self.source_id,
            "status": self.status.value,
            "error": self.error,
            "metadata": dict(self.metadata),
            "tool_count": len(self.tools),
        }
        if include_tools:
            data["tools"] = [tool.to_dict() for tool in self.tools]
        return data


class ExternalToolSource(Protocol):
    """外部工具源适配器协议。"""

    source_id: str

    async def start(self) -> None: ...

    async def stop(self) -> None: ...

    async def list_tools(self) -> list[ExternalToolDefinition]: ...

    async def call_tool(self, tool_name: str, arguments: dict[str, Any]) -> Any: ...


class ExternalToolManager:
    """外部工具生命周期与调用代理边界。

    当前实现是轻量预研层：支持注册适配器、状态快照、容错枚举与命名隔离；
    未来 MCP stdio/http 适配器应实现 ExternalToolSource 协议并接入这里。
    """

    def __init__(self) -> None:
        self._sources: dict[str, ExternalToolSource] = {}
        self._states: dict[str, ExternalToolSourceState] = {}

    def register_source(self, source: ExternalToolSource) -> None:
        source_id = normalize_external_name(source.source_id, kind="source_id")
        if source_id in self._sources:
            raise ValueError(f"External tool source already registered: {source_id}")
        self._sources[source_id] = source
        self._states[source_id] = ExternalToolSourceState(source_id=source_id)

    def unregister_source(self, source_id: str) -> bool:
        source_id = normalize_external_name(source_id, kind="source_id")
        removed = self._sources.pop(source_id, None) is not None
        self._states.pop(source_id, None)
        return removed

    def source_status(self, *, include_tools: bool = True) -> dict[str, Any]:
        sources = [
            self._states[source_id].to_dict(include_tools=include_tools)
            for source_id in sorted(self._states)
        ]
        return {
            "sources": sources,
            "source_count": len(sources),
            "tool_count": sum(source["tool_count"] for source in sources),
        }

    async def start_source(self, source_id: str) -> ExternalToolSourceState:
        source_id = normalize_external_name(source_id, kind="source_id")
        source = self._require_source(source_id)
        state = self._states[source_id]
        state.status = ExternalToolSourceStatus.STARTING
        state.error = None
        try:
            await source.start()
            state.status = ExternalToolSourceStatus.RUNNING
            state.tools = await self._safe_list_source_tools(source_id, source)
        except Exception as exc:
            state.status = ExternalToolSourceStatus.FAILED
            state.error = str(exc)
        return state

    async def stop_source(self, source_id: str) -> ExternalToolSourceState:
        source_id = normalize_external_name(source_id, kind="source_id")
        source = self._require_source(source_id)
        state = self._states[source_id]
        state.status = ExternalToolSourceStatus.STOPPING
        try:
            await source.stop()
            state.status = ExternalToolSourceStatus.STOPPED
        except Exception as exc:
            state.status = ExternalToolSourceStatus.FAILED
            state.error = str(exc)
        return state

    async def list_tools(self, *, refresh: bool = False) -> list[ExternalToolDefinition]:
        tools: list[ExternalToolDefinition] = []
        for source_id in sorted(self._sources):
            source = self._sources[source_id]
            state = self._states[source_id]
            if refresh:
                state.tools = await self._safe_list_source_tools(source_id, source)
            tools.extend(state.tools)
        tools.sort(key=lambda item: item.namespaced_name)
        return tools

    async def call_tool(self, namespaced_name: str, arguments: dict[str, Any]) -> Any:
        source_id, tool_name = split_external_tool_name(namespaced_name)
        source = self._require_source(source_id)
        try:
            return await source.call_tool(tool_name, arguments)
        except ToolExecutionError:
            raise
        except Exception as exc:
            raise ToolExecutionError(
                ToolError(
                    error_code="external_tool.call_failed",
                    technical_message=str(exc),
                    user_message="外部工具调用失败。",
                    recoverable=True,
                    action_hint="请检查外部工具源状态后重试。",
                    details={"source_id": source_id, "tool_name": tool_name},
                )
            ) from exc

    async def _safe_list_source_tools(
        self,
        source_id: str,
        source: ExternalToolSource,
    ) -> list[ExternalToolDefinition]:
        state = self._states[source_id]
        try:
            tools = await source.list_tools()
            normalized = [normalize_external_tool_definition(tool) for tool in tools]
            state.error = None
            return normalized
        except Exception as exc:
            state.status = ExternalToolSourceStatus.FAILED
            state.error = str(exc)
            return []

    def _require_source(self, source_id: str) -> ExternalToolSource:
        source = self._sources.get(source_id)
        if source is None:
            raise KeyError(f"Unknown external tool source: {source_id}")
        return source


def normalize_external_name(value: str, *, kind: str) -> str:
    """校验外部工具源/工具名片段，避免注入分隔符或非法字符。"""

    if not value or not _EXTERNAL_NAME_PATTERN.fullmatch(value):
        raise ValueError(f"Invalid external {kind}: {value!r}")
    if "__" in value:
        raise ValueError(f"External {kind} must not contain double underscores: {value!r}")
    return value


def make_external_tool_name(source_id: str, tool_name: str) -> str:
    """生成外部工具命名空间名称：external__server__tool。"""

    source_id = normalize_external_name(source_id, kind="source_id")
    tool_name = normalize_external_name(tool_name, kind="tool_name")
    return f"{EXTERNAL_TOOL_PREFIX}__{source_id}__{tool_name}"


def is_external_tool_name(name: str) -> bool:
    return bool(_EXTERNAL_TOOL_NAME_PATTERN.fullmatch(name))


def split_external_tool_name(name: str) -> tuple[str, str]:
    if not is_external_tool_name(name):
        raise ValueError(f"Invalid external tool name: {name!r}")
    _, source_id, tool_name = name.split("__", 2)
    return source_id, tool_name


def normalize_external_tool_definition(tool: ExternalToolDefinition) -> ExternalToolDefinition:
    expected = make_external_tool_name(tool.source_id, tool.tool_name)
    if tool.namespaced_name != expected:
        raise ValueError(
            f"External tool namespaced_name mismatch: expected {expected!r}, got {tool.namespaced_name!r}"
        )
    return tool


__all__ = [
    "EXTERNAL_TOOL_PREFIX",
    "ExternalToolDefinition",
    "ExternalToolManager",
    "ExternalToolSource",
    "ExternalToolSourceState",
    "ExternalToolSourceStatus",
    "is_external_tool_name",
    "make_external_tool_name",
    "normalize_external_name",
    "normalize_external_tool_definition",
    "split_external_tool_name",
]
