"""Filesystem behaviour of the rule-loading installer, without an LLM or network."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1)).resolve()


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo with spaces"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.target = self.repo / "AGENTS.md"

    def run_setup(self, mode="install", where=None, code=0):
        p = subprocess.run(
            [sys.executable, str(SCRIPT), mode, "--repo", str(where or self.repo)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)
        return p.stdout

    def test_check_does_not_create_file(self):
        self.run_setup("check", code=1)
        self.assertFalse(self.target.exists())
        self.assertEqual(sorted(p.name for p in self.repo.iterdir()), [".git"])

    def test_install_preserves_prose_bytes_rules_and_old_skill(self):
        old = b"# Owner\r\n\r\nKeep this rule.\r\n"
        self.target.write_bytes(old)
        self.target.chmod(0o640)
        rule = self.repo / ".claude/rules/custom.md"
        rule.parent.mkdir(parents=True)
        rule.write_text("Custom rule")
        skill = self.repo / ".agents/skills/legacy/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("Legacy skill")
        self.run_setup()
        self.assertTrue(self.target.read_bytes().endswith(old))
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o640)
        self.assertEqual(rule.read_text(), "Custom rule")
        self.assertEqual(skill.read_text(), "Legacy skill")
        self.assertFalse((self.repo / "CLAUDE.md").exists())

    def test_large_file_starts_with_loading_instruction(self):
        original = "# Project\n" + "Existing instruction.\n" * 1800
        self.target.write_text(original)
        self.run_setup()
        result = self.target.read_text()
        self.assertTrue(result.startswith("<!-- agent-rules:begin -->"))
        self.assertTrue(result.endswith(original))

    def test_existing_late_block_moves_before_large_prose(self):
        self.run_setup()
        block = self.target.read_text()
        original = "# Owner\n" + "Keep this instruction.\n" * 1800
        self.target.write_text(original + block)
        output = self.run_setup()
        self.assertIn("32 KiB", output)
        self.assertTrue(self.target.read_text().startswith(block))
        self.assertIn(original, self.target.read_text())
        self.assertEqual(self.target.read_text().count("<!-- agent-rules:begin -->"), 1)

    def test_repeated_install_and_check_do_not_write(self):
        self.run_setup()
        original = self.target.read_bytes()
        before = self.target.stat().st_mtime_ns
        self.run_setup()
        self.run_setup("check")
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(self.target.stat().st_mtime_ns, before)

    def test_override_is_effective_target(self):
        self.target.write_text("Root stays intact")
        override = self.repo / "AGENTS.override.md"
        override.write_text("Override")
        self.run_setup()
        self.assertEqual(self.target.read_text(), "Root stays intact")
        self.assertTrue(override.read_text().endswith("Override"))
        self.assertIn("agent-rules:begin", override.read_text())

    def test_empty_override_is_populated(self):
        override = self.repo / "AGENTS.override.md"
        override.touch()
        self.run_setup()
        self.assertIn("agent-rules:begin", override.read_text())
        self.assertFalse(self.target.exists())

    def test_modified_block_is_not_overwritten(self):
        self.run_setup()
        text = self.target.read_text().replace(
            "Repository rule loading", "My changed loading"
        )
        self.target.write_text(text)
        self.run_setup(code=2)
        self.assertEqual(self.target.read_text(), text)

    def test_malformed_markers_are_not_overwritten(self):
        for text in (
            "<!-- agent-rules:begin -->",
            "<!-- agent-rules:end -->",
            "<!-- agent-rules:end -->\n<!-- agent-rules:begin -->",
            "<!-- agent-rules:begin -->\n<!-- agent-rules:begin -->\n<!-- agent-rules:end -->",
        ):
            with self.subTest(text=text):
                self.target.write_text(text)
                self.run_setup(code=2)
                self.assertEqual(self.target.read_text(), text)

    def test_symlink_is_not_followed_for_writes(self):
        external = Path(self.tmp.name) / "owner.md"
        external.write_text("Owner")
        self.target.symlink_to(external)
        self.run_setup(code=2)
        self.assertEqual(external.read_text(), "Owner")
        self.assertTrue(self.target.is_symlink())

    def test_dangling_override_is_not_bypassed(self):
        (self.repo / "AGENTS.override.md").symlink_to("missing.md")
        self.run_setup(code=2)
        self.assertFalse(self.target.exists())

    def test_nested_directory_uses_git_root(self):
        nested = self.repo / "src/worker"
        nested.mkdir(parents=True)
        self.run_setup(where=nested)
        self.assertTrue(self.target.exists())
        self.assertFalse((nested / "AGENTS.md").exists())

    def test_non_repo_has_no_writes(self):
        self.run_setup(where=Path(self.tmp.name), code=2)
        self.assertFalse((Path(self.tmp.name) / "AGENTS.md").exists())

    def test_worktree_changes_only_worktree(self):
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "fixture",
            ],
            check=True,
        )
        worktree = Path(self.tmp.name) / "worktree"
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "worktree",
                "add",
                "-q",
                "-b",
                "test",
                str(worktree),
            ],
            check=True,
        )
        self.run_setup(where=worktree)
        self.assertTrue((worktree / "AGENTS.md").exists())
        self.assertFalse(self.target.exists())


if __name__ == "__main__":
    unittest.main()
