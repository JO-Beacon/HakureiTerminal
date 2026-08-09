import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts.scan_forbidden_runtime_assets import (
    artifact_violation,
    scan_archive,
    scan_directory,
    scan_source,
    source_content_violation,
    source_violation,
)


class SourceBoundaryTests(unittest.TestCase):
    def test_allows_mentions_adapters_plans_and_tests(self) -> None:
        for path in (
            "README.md",
            "docs/GensokyoAI-migration.md",
            "plans/gensokyoai-removal.md",
            "lib/services/gensokyoai_adapter.dart",
            "tests/test_gensokyoai_adapter.py",
        ):
            self.assertIsNone(source_violation(path), path)

    def test_rejects_implementation_and_payload_paths(self) -> None:
        paths = (
            "backend/GensokyoAI/core/agent.py",
            "vendor/GensokyoAI/runtime.py",
            "characters/zh_cn/Reimu.yaml",
            "dist/GensokyoAI-1.0-py3-none-any.whl",
            "site-packages/GensokyoAI-1.0.dist-info/METADATA",
            "build/GensokyoAI.egg-info/PKG-INFO",
        )
        for path in paths:
            self.assertIsNotNone(source_violation(path), path)

    def test_source_scan_ignores_tracked_files_deleted_from_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("GensokyoAI interoperability", encoding="utf-8")
            violations = scan_source(
                root,
                ["README.md", "backend/GensokyoAI/core.py", "characters/old.yaml"],
            )
        self.assertEqual(violations, [])

    def test_rejects_local_execution_and_direct_provider_code(self) -> None:
        for content in (
            "final backend = BuiltinChatBackend();",
            "final providers = ProviderRegistry();",
            'const endpoint = "https://api.openai.com/v1";',
        ):
            self.assertIsNotNone(
                source_content_violation("lib/services/runtime/client.dart", content)
            )
        self.assertIsNone(
            source_content_violation(
                "test/runtime_boundary_test.dart", "BuiltinChatBackend"
            )
        )

    def test_source_scan_reads_active_dart_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "lib" / "runtime.dart"
            source.parent.mkdir(parents=True)
            source.write_text("final registry = ProviderRegistry();", encoding="utf-8")
            violations = scan_source(root, ["lib/runtime.dart"])
        self.assertEqual(len(violations), 1)
        self.assertIn("ProviderRegistry", violations[0])


class ArtifactBoundaryTests(unittest.TestCase):
    def test_allows_independent_application_files(self) -> None:
        for path in (
            "hakurei_terminal.exe",
            "data/characters/user-created.yaml",
            "lib/gensokyoai_adapter.dart",
            "THIRD_PARTY_LICENSES.md",
        ):
            self.assertIsNone(artifact_violation(path), path)

    def test_rejects_stage_five_and_third_party_payloads(self) -> None:
        paths = (
            "bridge_main.py",
            "lib/runtime_http.py",
            "python/runtime/python.exe",
            "assets/python/runtime/python314.dll",
            "share/GensokyoAI/core.py",
            "wheels/GensokyoAI-1.0-py3-none-any.whl",
            "characters/Reimu.yaml",
            "scenes/default.yaml",
            "config/default.yaml",
        )
        for path in paths:
            self.assertIsNotNone(artifact_violation(path), path)

    def test_directory_scan_checks_empty_forbidden_layouts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "assets" / "python").mkdir(parents=True)
            violations = scan_directory(root)
        self.assertTrue(any("assets/python" in item for item in violations))

    def test_zip_and_apk_scan_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for extension in ("zip", "apk"):
                archive = root / f"release.{extension}"
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr("app/ok.txt", "ok")
                    output.writestr("python/runtime/python.exe", b"python")
                self.assertTrue(scan_archive(archive), extension)

    def test_rejects_archive_traversal_and_absolute_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "release.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("../escape.txt", "bad")
                output.writestr("C:\\escape.txt", "bad")
                output.writestr("/absolute.txt", "bad")
            violations = scan_archive(archive)
        self.assertEqual(len(violations), 3)
        self.assertTrue(all("traversal or absolute" in item for item in violations))


if __name__ == "__main__":
    unittest.main()
