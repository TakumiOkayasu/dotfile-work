#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATOR = REPO_ROOT / "scripts" / "generate-ai-assets.py"


def copy_repository(destination: Path) -> Path:
    repo = destination / "repo"
    shutil.copytree(
        REPO_ROOT,
        repo,
        ignore=shutil.ignore_patterns(
            ".git",
            ".generated",
            ".stow-work",
            "plugins",
            "__pycache__",
        ),
    )
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(
        [
            "git",
            "add",
            "--",
            "common",
            "claude",
            "codex",
            "scripts",
            "install.sh",
        ],
        cwd=repo,
        check=True,
    )
    return repo


def run_generator(repo: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(repo / "scripts" / GENERATOR.name), "--repo", str(repo)],
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=60,
    )


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


class TestGenerateAiAssets(unittest.TestCase):
    def assert_generated_views(self, generated: Path) -> None:
        claude_skill = generated / "claude" / "skills" / "tdd" / "SKILL.md"
        codex_skill = generated / "codex" / "skills" / "tdd" / "SKILL.md"
        plugin_skill = (
            generated
            / "plugins"
            / "dotfile-work-codex"
            / "skills"
            / "tdd"
            / "SKILL.md"
        )
        self.assertIn("INSTALL_GENERATION_SENTINEL", claude_skill.read_text())
        self.assertIn("INSTALL_GENERATION_SENTINEL", codex_skill.read_text())
        self.assertIn("INSTALL_GENERATION_SENTINEL", plugin_skill.read_text())
        self.assertFalse((generated / "claude" / "skills" / "untracked-only").exists())
        self.assertFalse((generated / "codex" / "skills" / "untracked-only").exists())
        self.assertTrue(
            (generated / ".agents" / "plugins" / "marketplace.json").is_file()
        )
        marketplace = json.loads(
            (generated / ".agents" / "plugins" / "marketplace.json").read_text()
        )
        self.assertEqual(
            {plugin["source"]["path"] for plugin in marketplace["plugins"]},
            {
                "./.codex/plugins/dotfile-work-codex",
                "./.codex/plugins/dotfile-work-codex-extra",
            },
        )

    def test_repository_tracks_sources_not_generated_codex_views(self) -> None:
        tracked = subprocess.run(
            ["git", "ls-files", "-z", "--", "codex/skills", "codex/rules"],
            cwd=REPO_ROOT,
            capture_output=True,
            check=True,
        ).stdout
        paths = {
            path
            for raw in tracked.split(b"\0")
            if raw
            for path in (raw.decode("utf-8"),)
            if (REPO_ROOT / path).is_file()
        }

        self.assertEqual(
            paths,
            {
                "codex/skills/rules-compliance-review/SKILL.md",
            },
        )

    def test_generates_claude_codex_and_plugin_views_from_tracked_common(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = copy_repository(Path(directory))
            shared_skill = repo / "common" / "skills" / "tdd" / "SKILL.md"
            shared_skill.write_text(
                shared_skill.read_text(encoding="utf-8") + "\nINSTALL_GENERATION_SENTINEL\n",
                encoding="utf-8",
            )
            subprocess.run(
                ["git", "add", "--", "common/skills/tdd/SKILL.md"],
                cwd=repo,
                check=True,
            )
            untracked_skill = repo / "common" / "skills" / "untracked-only"
            untracked_skill.mkdir()
            (untracked_skill / "SKILL.md").write_text(
                "---\nname: untracked-only\ndescription: must stay local\n---\n",
                encoding="utf-8",
            )

            result = run_generator(repo)

            self.assertEqual(result.returncode, 0, result.stderr)
            generated = repo / ".generated" / "ai-assets"
            self.assert_generated_views(generated)

            first_digest = tree_digest(generated)
            repeated = run_generator(repo)
            self.assertEqual(repeated.returncode, 0, repeated.stderr)
            self.assertEqual(tree_digest(generated), first_digest)

    def test_dads_rule_reaches_both_runtimes_and_core_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = copy_repository(Path(directory))
            rule_name = "dads-design.md"
            source = repo / "common" / "rules" / rule_name
            original = source.read_text(encoding="utf-8")
            updated = original + "\nDADS_UPDATE_SENTINEL\n"
            for expected in (original, updated):
                source.write_text(expected, encoding="utf-8")
                result = run_generator(repo)
                self.assertEqual(result.returncode, 0, result.stderr)
                generated = repo / ".generated" / "ai-assets"
                self.assertEqual(
                    (generated / "claude" / "rules" / rule_name).read_text(), expected
                )
                for view in ("codex", "plugins/dotfile-work-codex"):
                    rule = (generated / view / "rules" / rule_name).read_text()
                    self.assertIn("# DADS Design Baseline", rule)
                    self.assertIn("Yellow-300", rule)
                    self.assertEqual("DADS_UPDATE_SENTINEL" in rule, expected == updated)
                    for name in ("RULES_INDEX.md", "RULES_BUNDLE.md"):
                        self.assertIn(
                            rule_name, (generated / view / "rules" / name).read_text()
                        )
                self.assertIn(
                    rule_name, (generated / "codex" / "global_AGENTS.md").read_text()
                )
                manifest = json.loads((generated / "manifest.json").read_text())
                for target, destination in (
                    ("claude", f".claude/rules/{rule_name}"),
                    ("codex", f".codex/rules/{rule_name}"),
                    ("codex", f".codex/plugins/dotfile-work-codex/rules/{rule_name}"),
                ):
                    entries = [
                        entry for entry in manifest["targets"][target]
                        if entry["destination"] == destination
                    ]
                    self.assertEqual(len(entries), 1, destination)
                    content = (generated / entries[0]["source"]).read_bytes()
                    self.assertEqual(
                        entries[0]["sha256"], hashlib.sha256(content).hexdigest()
                    )
                self.assertEqual(source.read_text(), expected)

    def test_failed_generation_preserves_last_complete_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = copy_repository(Path(directory))
            first = run_generator(repo)
            self.assertEqual(first.returncode, 0, first.stderr)
            generated = repo / ".generated" / "ai-assets"
            before = tree_digest(generated)

            invalid_resource = repo / "common" / "skills" / "tdd" / "invalid.bin"
            invalid_resource.write_bytes(b"unsupported tracked resource")
            subprocess.run(
                ["git", "add", "--", "common/skills/tdd/invalid.bin"],
                cwd=repo,
                check=True,
            )

            failed = run_generator(repo)

            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(tree_digest(generated), before)

    def test_installer_stops_before_home_changes_when_generation_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = copy_repository(root)
            home = root / "home"
            home.mkdir()
            invalid_resource = repo / "common" / "skills" / "tdd" / "invalid.bin"
            invalid_resource.write_bytes(b"unsupported tracked resource")
            subprocess.run(
                ["git", "add", "--", "common/skills/tdd/invalid.bin"],
                cwd=repo,
                check=True,
            )

            result = subprocess.run(
                ["sh", str(repo / "install.sh"), "-f"],
                cwd=repo,
                env={**os.environ, "HOME": str(home)},
                capture_output=True,
                text=True,
                timeout=60,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(home.iterdir()), [])

    def test_installer_uses_generated_views_for_shared_ai_assets(self) -> None:
        install_script = (REPO_ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn("scripts/generate-ai-assets.py", install_script)
        self.assertIn(".generated/ai-assets/claude", install_script)
        self.assertIn(".generated/ai-assets/codex", install_script)
        self.assertIn(".generated/ai-assets/plugins", install_script)


class TestDadsDesignPolicy(unittest.TestCase):
    """Check the instruction contract, not the quality of model-generated designs."""

    def read_rule(self) -> str:
        path = REPO_ROOT / "common" / "rules" / "dads-design.md"
        self.assertTrue(path.is_file(), "The shared DADS rule must be distributed")
        return path.read_text(encoding="utf-8")

    def test_rule_is_unscoped_and_global_instructions_route_design_work(self) -> None:
        global_text = (REPO_ROOT / "codex" / "global_AGENTS.md").read_text()
        self.assertIn("dads-design.md", global_text)
        self.assertIn("DADS", global_text)
        rule = self.read_rule()
        self.assertTrue(rule.startswith("# DADS Design Baseline\n"))
        self.assertNotIn("paths:", rule)
        self.assertIn("明示的にDADSを指定しなくても", rule)
        self.assertIn("API/DB設計", rule)

    def test_all_foundations_have_primary_sources(self) -> None:
        rule = self.read_rule()
        base = "https://design.digital.go.jp/dads/foundations/"
        for topic in (
            "color", "typography", "icon", "layout", "link-text", "spacing",
            "corner-shapes", "elevation",
        ):
            with self.subTest(topic=topic):
                self.assertIn(f"{base}{topic}/", rule)
        self.assertIn("確認日:", rule)
        self.assertIn("必須・推奨・作例", rule)

    def test_policy_covers_design_delegation_and_evidence_before_completion(self) -> None:
        rule = self.read_rule()
        for section in ("## 適用", "## 設計前", "## 設計・実装中", "## 出力前"):
            self.assertIn(section, rule)
        for required in ("委譲", "passed", "failed", "unverified", "not-applicable"):
            self.assertIn(required, rule)
        self.assertIn("未検証を準拠済みと報告しない", rule)
        self.assertIn("スクリーンショット", rule)
        self.assertIn("キーボード", rule)
        self.assertIn("無関係な画面", rule)

    def test_critical_constraints_do_not_turn_examples_into_requirements(self) -> None:
        rule = self.read_rule()
        for required in ("4.5:1", "3:1", "Yellow-300", "Black", "44x44", "24x24"):
            self.assertIn(required, rule)
        self.assertIn("システムフォント", rule)
        self.assertIn("768px", rule)
        self.assertIn("8px", rule)
        self.assertIn("固定しない", rule)

    def test_rule_does_not_bind_external_design_skill_names(self) -> None:
        rule = self.read_rule()
        for name in ("Product Design", "Claude Design", "frontend-design", "@Design"):
            self.assertNotIn(name, rule)
        self.assertIn("特定の製品名・スキル名", rule)


if __name__ == "__main__":
    unittest.main()
