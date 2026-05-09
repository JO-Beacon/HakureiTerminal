import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from GensokyoAI.core.agent.types import ModelInfo, ProviderCapability
from GensokyoAI.core.config import ModelConfig
from GensokyoAI.runtime.dependencies import (
    OPTIONAL_PROVIDER_DEPENDENCIES,
    DependencyError,
    dependency_status,
    packages_for_providers,
)
from GensokyoAI.runtime.rpc import (
    RpcMethodNotFoundError,
    dispatch_rpc,
    legacy_rpc_methods,
    resolve_rpc_handler,
    rpc_methods,
)
from GensokyoAI.tools.errors import ToolError, ToolExecutionError
from GensokyoAI.runtime.service import RuntimeService


class RuntimeDependencyTests(unittest.TestCase):
    def test_dependency_mapping_includes_expected_provider_aliases(self):
        self.assertEqual(OPTIONAL_PROVIDER_DEPENDENCIES["deepseek"], ["openai>=1.0.0"])
        self.assertEqual(
            packages_for_providers(["openai", "deepseek", "openai_responses"]),
            ["openai>=1.0.0"],
        )

    def test_dependency_status_reports_missing_imports(self):
        def fake_find_spec(name):
            return object() if name == "openai" else None

        with patch("importlib.util.find_spec", side_effect=fake_find_spec):
            status = dependency_status(["deepseek", "claude"])

        self.assertTrue(status["providers"]["deepseek"]["installed"])
        self.assertFalse(status["providers"]["claude"]["installed"])
        self.assertEqual(status["providers"]["claude"]["missing_imports"], ["anthropic"])

    def test_dependency_status_rejects_unknown_provider(self):
        with self.assertRaises(DependencyError) as ctx:
            dependency_status(["not-a-provider"])

        self.assertEqual(ctx.exception.code, "unsupported_provider_dependency")
        self.assertIn("not-a-provider", ctx.exception.details["providers"])

    def test_runtime_service_exposes_dependency_and_model_methods(self):
        service = RuntimeService()

        async def run():
            with patch("importlib.util.find_spec", return_value=None):
                status = await service.handle(
                    "dependency.status",
                    {"providers": ["openai"]},
                )
            legacy = await service.handle("dependency_status", {"providers": []})
            info = await service.handle("runtime.info")
            return status, legacy, info

        status, legacy, info = asyncio.run(run())

        self.assertIn("openai", status["providers"])
        self.assertEqual(legacy["providers"], {})
        self.assertIn("dependency.status", info["methods"])
        self.assertIn("model.list", info["methods"])
        self.assertIn("model.info", info["methods"])
        self.assertIn("install_dependencies", info["legacy_methods"])


class FakeModelRegistry:
    def __init__(self):
        self.list_calls = []
        self.info_calls = []

    async def list_models(self, config, *, refresh=False, overrides=None):
        self.list_calls.append((config, refresh, overrides))
        return [
            ModelInfo(
                id="gpt-test",
                name="GPT Test",
                context_window=4096,
                capabilities=[ProviderCapability.CHAT, ProviderCapability.TOOLS],
                owned_by="tests",
                metadata={"source": "fake"},
            )
        ]

    async def get_model_info(self, config, model_id=None, *, refresh=False, overrides=None):
        self.info_calls.append((config, model_id, refresh, overrides))
        return ModelInfo(
            id=model_id or config.name,
            name="Selected Test Model",
            context_window=8192,
            capabilities=[ProviderCapability.CHAT],
            owned_by="tests",
            metadata={"selected": True},
        )


class RuntimeModelRpcTests(unittest.TestCase):
    def test_model_list_and_info_return_json_compatible_model_metadata(self):
        service = RuntimeService()
        fake_registry = FakeModelRegistry()
        service._model_registry = fake_registry
        service.state.agent = SimpleNamespace(
            config=SimpleNamespace(model=ModelConfig(provider="openai", name="gpt-test"))
        )

        async def run():
            listed = await service.handle(
                "model.list",
                {
                    "refresh": True,
                    "overrides": {
                        "gpt-test": {
                            "capabilities_add": ["custom"],
                        }
                    },
                },
            )
            info = await service.handle("model.info", {"model_id": "gpt-test-v2"})
            return listed, info

        listed, info = asyncio.run(run())

        self.assertEqual(listed["provider"], "openai")
        self.assertEqual(listed["model"], "gpt-test")
        self.assertEqual(listed["models"][0]["id"], "gpt-test")
        self.assertEqual(listed["models"][0]["context_window"], 4096)
        self.assertIn(ProviderCapability.TOOLS, listed["models"][0]["capabilities"])
        self.assertEqual(listed["models"][0]["metadata"], {"source": "fake"})
        self.assertTrue(fake_registry.list_calls[0][1])
        self.assertIn("gpt-test", fake_registry.list_calls[0][2])

        self.assertEqual(info["provider"], "openai")
        self.assertEqual(info["requested_model"], "gpt-test-v2")
        self.assertEqual(info["model"]["id"], "gpt-test-v2")
        self.assertEqual(info["model"]["metadata"], {"selected": True})
        self.assertEqual(fake_registry.info_calls[0][1], "gpt-test-v2")


class RuntimeRpcDispatchTests(unittest.TestCase):
    def test_rpc_method_lists_are_owned_by_runtime_rpc_module(self):
        self.assertIn("runtime.info", rpc_methods())
        self.assertIn("dependency.status", rpc_methods())
        self.assertIn("model.list", rpc_methods())
        self.assertIn("model.info", rpc_methods())
        self.assertNotIn("init", rpc_methods())
        self.assertIn("init", legacy_rpc_methods())
        self.assertIn("install_dependencies", legacy_rpc_methods())

    def test_resolve_rpc_handler_maps_namespaced_and_legacy_methods(self):
        service = RuntimeService()

        self.assertEqual(resolve_rpc_handler(service, "runtime.info").__name__, "info")
        self.assertEqual(resolve_rpc_handler(service, "init").__name__, "init")
        self.assertEqual(
            resolve_rpc_handler(service, "dependency.status").__name__,
            "dependency_status",
        )
        self.assertEqual(resolve_rpc_handler(service, "model.list").__name__, "list_models")
        self.assertEqual(resolve_rpc_handler(service, "model.info").__name__, "model_info")

    def test_dispatch_rpc_raises_structured_method_not_found_error(self):
        service = RuntimeService()

        async def run():
            await dispatch_rpc(service, "not.registered", {})

        with self.assertRaises(RpcMethodNotFoundError) as ctx:
            asyncio.run(run())

        self.assertEqual(ctx.exception.code, "method_not_found")
        self.assertTrue(ctx.exception.recoverable)
        self.assertEqual(ctx.exception.details["method"], "not.registered")
        self.assertIn("runtime.info", ctx.exception.details["allowed_methods"])

    def test_runtime_service_handle_returns_structured_error_response_by_default(self):
        service = RuntimeService()

        async def run():
            return await service.handle("not.registered", {})

        response = asyncio.run(run())

        self.assertFalse(response["ok"])
        self.assertEqual(response["error_code"], "method_not_found")
        self.assertIn("Unknown method", response["error"])
        self.assertEqual(response["error_object"]["code"], "method_not_found")
        self.assertEqual(response["error_object"]["details"]["method"], "not.registered")
        self.assertIn("user_message", response["error_object"])

    def test_dispatch_rpc_can_wrap_tool_execution_error_as_runtime_error_response(self):
        class ToolFailingService:
            async def info(self):
                raise ToolExecutionError(
                    ToolError(
                        error_code="tool.test_failed",
                        technical_message="tool technical failure",
                        user_message="tool user failure",
                        recoverable=False,
                        details={"scope": "runtime"},
                    )
                )

        async def run():
            return await dispatch_rpc(ToolFailingService(), "runtime.info", {}, structured_errors=True)

        response = asyncio.run(run())

        self.assertFalse(response["ok"])
        self.assertEqual(response["error_code"], "tool.test_failed")
        self.assertEqual(response["error"], "tool technical failure")
        self.assertEqual(response["error_object"]["user_message"], "tool user failure")
        self.assertFalse(response["error_object"]["recoverable"])
        self.assertEqual(response["error_object"]["details"], {"scope": "runtime"})


if __name__ == "__main__":
    unittest.main()
