import asyncio
import unittest

from GensokyoAI.core.agent.types import ProviderCapability
from GensokyoAI.core.config import ModelConfig, ToolConfig
from GensokyoAI.core.events import SystemEvent
from GensokyoAI.runtime.rpc import external_tool_status_methods, rpc_methods, legacy_rpc_methods
from GensokyoAI.runtime.service import RuntimeService
from GensokyoAI.tools.build_service import ToolBuildContext, ToolBuildService
from GensokyoAI.tools.external_manager import (
    ExternalToolDefinition,
    ExternalToolManager,
    ExternalToolSourceStatus,
    is_external_tool_name,
    make_external_tool_name,
    split_external_tool_name,
)
from GensokyoAI.tools.registry import ToolRegistry


def _schema(name: str) -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": "external test tool",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    }


class FakeExternalSource:
    def __init__(self, source_id="server", *, fail_list=False):
        self.source_id = source_id
        self.fail_list = fail_list
        self.calls = []

    async def start(self):
        return None

    async def stop(self):
        return None

    async def list_tools(self):
        if self.fail_list:
            raise RuntimeError("list failed")
        return [
            ExternalToolDefinition(
                source_id=self.source_id,
                tool_name="search",
                namespaced_name=make_external_tool_name(self.source_id, "search"),
                description="External search",
                schema=_schema("search"),
                metadata={"transport": "fake"},
            )
        ]

    async def call_tool(self, tool_name, arguments):
        self.calls.append((tool_name, arguments))
        return {"tool_name": tool_name, "arguments": arguments}


class ExternalToolManagerContractTests(unittest.TestCase):
    def test_namespaced_external_tool_name_contract(self):
        name = make_external_tool_name("server", "search")

        self.assertEqual(name, "external__server__search")
        self.assertTrue(is_external_tool_name(name))
        self.assertEqual(split_external_tool_name(name), ("server", "search"))

        with self.assertRaises(ValueError):
            make_external_tool_name("bad__server", "search")
        with self.assertRaises(ValueError):
            split_external_tool_name("search")

    def test_manager_lists_tools_with_source_failure_isolation(self):
        manager = ExternalToolManager()
        manager.register_source(FakeExternalSource("ok"))
        manager.register_source(FakeExternalSource("bad", fail_list=True))

        async def run():
            return await manager.list_tools(refresh=True), manager.source_status()

        tools, status = asyncio.run(run())

        self.assertEqual([tool.namespaced_name for tool in tools], ["external__ok__search"])
        states = {source["source_id"]: source for source in status["sources"]}
        self.assertEqual(states["ok"]["tool_count"], 1)
        self.assertEqual(states["bad"]["status"], ExternalToolSourceStatus.FAILED.value)
        self.assertEqual(states["bad"]["tool_count"], 0)
        self.assertIn("list failed", states["bad"]["error"])

    def test_manager_call_tool_proxies_to_source_without_registry_pollution(self):
        manager = ExternalToolManager()
        source = FakeExternalSource("server")
        manager.register_source(source)

        async def run():
            await manager.list_tools(refresh=True)
            return await manager.call_tool("external__server__search", {"q": "test"})

        result = asyncio.run(run())

        self.assertEqual(result["tool_name"], "search")
        self.assertEqual(source.calls, [("search", {"q": "test"})])
        self.assertIsNone(ToolRegistry().get("external__server__search"))


class ExternalToolRuntimeAndBuildTests(unittest.TestCase):
    def test_runtime_exposes_external_tool_status_rpc(self):
        service = RuntimeService()
        service.external_tool_manager.register_source(FakeExternalSource("server"))

        async def run():
            await service.external_tool_manager.list_tools(refresh=True)
            status = await service.handle("external_tool.status")
            legacy = await service.handle("external_tool_status", {"include_tools": False})
            info = await service.handle("runtime.info")
            return status, legacy, info

        status, legacy, info = asyncio.run(run())

        self.assertIn("external_tool.status", rpc_methods())
        self.assertIn("external_tool_status", legacy_rpc_methods())
        self.assertEqual(status["source_count"], 1)
        self.assertEqual(status["tool_count"], 1)
        self.assertEqual(status["sources"][0]["tools"][0]["namespaced_name"], "external__server__search")
        self.assertNotIn("tools", legacy["sources"][0])
        self.assertIn("external_tools", info)

    def test_external_tool_status_event_contract_is_explicit(self):
        mapping = external_tool_status_methods()

        self.assertEqual(mapping["starting"], SystemEvent.EXTERNAL_TOOL_STARTING.value)
        self.assertEqual(mapping["running"], SystemEvent.EXTERNAL_TOOL_RUNNING.value)
        self.assertEqual(mapping["stopping"], SystemEvent.EXTERNAL_TOOL_STOPPING.value)
        self.assertEqual(mapping["failed"], SystemEvent.EXTERNAL_TOOL_FAILED.value)
        self.assertEqual(mapping["reconnecting"], SystemEvent.EXTERNAL_TOOL_RECONNECTING.value)

    def test_tool_build_service_accepts_external_schemas_without_registry_registration(self):
        external = ExternalToolDefinition(
            source_id="server",
            tool_name="search",
            namespaced_name="external__server__search",
            description="External search",
            schema=_schema("search"),
        )
        registry = ToolRegistry()
        service = ToolBuildService(registry)

        result = service.build(
            ToolBuildContext(
                tool_config=ToolConfig(enabled=True, builtin_tools=[]),
                model_config=ModelConfig(),
                model_capabilities={ProviderCapability.CHAT, ProviderCapability.TOOLS},
                external_tools=[external],
            )
        )

        names = [schema["function"]["name"] for schema in result.tools]
        self.assertIn("external__server__search", names)
        self.assertIn("external__server__search", result.enabled_tool_names)
        self.assertIn("external__server__search", result.instructions)
        self.assertIsNone(registry.get("external__server__search"))


if __name__ == "__main__":
    unittest.main()
