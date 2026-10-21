import contextlib
import io
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_release import IDENTITY, INSTALLER_IDENTITY, ROOT, release


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="si version ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "mac/SI.xcodeproj/project.pbxproj"
        self.project.parent.mkdir(parents=True)
        source = (ROOT / "mac/SI.xcodeproj/project.pbxproj").read_text()
        source = re.sub(r"MARKETING_VERSION = [^;]+;", "MARKETING_VERSION = 0.0.9;", source)
        source = re.sub(r"CURRENT_PROJECT_VERSION = [^;]+;", "CURRENT_PROJECT_VERSION = 10;", source)
        self.project.write_text(source)
        (self.root / ".gitignore").write_text(".build/\n")
        (self.root / "README.md").write_text("Synthetic release fixture\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Synthetic Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.root / ".git/hooks"))
        self.git("add", ".")
        self.git("commit", "-qm", "Initial synthetic source")
        self.original = self.project.read_text()
        self.revision = self.git("rev-parse", "HEAD")
        self.args = release.arguments(["--publish", "--arch", "arm64", "--sign", IDENTITY,
                                       "--installer-sign", INSTALLER_IDENTITY, "--notarize-profile", "test-notary"])

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def prepare(self):
        return release.prepare_version(self.root, self.args, release.project_version(self.root), self.git("rev-parse", "HEAD"))

    def invoke_main(self):
        with patch.object(release, "ROOT", self.root), patch.object(release.shutil, "which", return_value="fixture-tool"), \
                patch.object(release, "sparkle_tools"):
            release.main(["--publish", "--arch", "arm64", "--sign", IDENTITY,
                          "--installer-sign", INSTALLER_IDENTITY, "--notarize-profile", "test-notary"])

    def test_default_increments_patch_and_build_in_both_configurations_and_commits_exact_source(self):
        version, revision = self.prepare()
        self.assertEqual(version, "0.0.10")
        self.assertEqual(release.project_build(self.root), 11)
        self.assertEqual(self.project.read_text().count("MARKETING_VERSION = 0.0.10;"), 2)
        self.assertEqual(self.project.read_text().count("CURRENT_PROJECT_VERSION = 11;"), 2)
        self.assertNotEqual(revision, self.revision)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("show", f"{revision}:mac/SI.xcodeproj/project.pbxproj"), self.project.read_text().strip())
        self.assertEqual(self.git("diff", "--name-only", self.revision, revision), "mac/SI.xcodeproj/project.pbxproj")

    def test_no_bump_reuses_current_version_and_does_not_commit(self):
        self.args.no_bump = True
        self.assertEqual(self.prepare(), ("0.0.9", self.revision))
        self.assertEqual(self.project.read_text(), self.original)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "1")

    def test_failure_retry_reuses_pending_revision_until_success(self):
        first = self.prepare()
        self.assertEqual(self.prepare(), first)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")
        release.pending_path(self.root, self.args.arch).unlink()
        second = self.prepare()
        self.assertEqual(second[0], "0.0.11")
        self.assertEqual(release.project_build(self.root), 12)
        self.assertNotEqual(second[1], first[1])

    def test_changed_committed_source_starts_a_new_patch_after_failure(self):
        self.prepare()
        (self.root / "README.md").write_text("Changed synthetic source\n")
        self.git("commit", "-qam", "Change synthetic source")
        self.assertEqual(self.prepare()[0], "0.0.11")

    def test_dirty_or_untracked_changes_prevent_version_mutation(self):
        path = self.root / "README.md"
        path.write_text("Uncommitted source\n")
        with self.assertRaisesRegex(ValueError, "checkout must be clean"):
            self.prepare()
        self.git("restore", "README.md")
        (self.root / "new-source").write_text("untracked\n")
        with self.assertRaisesRegex(ValueError, "checkout must be clean"):
            self.prepare()
        self.assertEqual(self.project.read_text(), self.original)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.revision)
        self.assertFalse(release.pending_path(self.root, self.args.arch).exists())

    def test_failed_version_commit_restores_only_its_metadata_edit(self):
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.assertEqual(self.project.read_text(), self.original)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.revision)
        self.assertFalse(release.pending_path(self.root, self.args.arch).exists())

    def test_interrupt_after_commit_recovers_without_a_second_increment(self):
        original = release.write_pending

        def interrupted(path, content):
            if content.get("revision"):
                raise OSError("synthetic interruption after commit")
            original(path, content)

        with patch.object(release, "write_pending", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "synthetic interruption"):
                self.prepare()
        revision = self.git("rev-parse", "HEAD")
        self.assertEqual(self.prepare(), ("0.0.10", revision))
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")

    def test_dry_run_prints_increment_without_files_or_commits(self):
        output = io.StringIO()
        with patch.object(release, "ROOT", self.root), contextlib.redirect_stdout(output):
            release.main(["--publish", "--arch", "arm64", "--sign", IDENTITY, "--installer-sign", INSTALLER_IDENTITY,
                          "--notarize-profile", "test-notary", "--dry-run"])
        self.assertIn("0.0.9 -> 0.0.10", output.getvalue())
        self.assertIn("build: 10 -> 11", output.getvalue())
        self.assertIn("releases/0.0.10/mac/arm64", output.getvalue())
        self.assertEqual(self.project.read_text(), self.original)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.revision)
        self.assertFalse((self.root / ".build").exists())

    def test_inconsistent_build_versions_stop_before_edit_or_commit(self):
        self.project.write_text(self.original.replace("CURRENT_PROJECT_VERSION = 10;", "CURRENT_PROJECT_VERSION = 9;", 1))
        self.git("commit", "-qam", "Synthetic inconsistent build metadata")
        before = self.project.read_text()
        revision = self.git("rev-parse", "HEAD")
        with self.assertRaisesRegex(ValueError, "same integer CURRENT_PROJECT_VERSION"):
            self.prepare()
        self.assertEqual(self.project.read_text(), before)
        self.assertEqual(self.git("rev-parse", "HEAD"), revision)

    def test_r2_preflight_failure_does_not_bump_or_commit(self):
        with patch.object(release, "Storage") as storage, patch.object(release, "prepare_release") as prepare:
            storage.return_value.preflight.side_effect = ValueError("synthetic R2 preflight error")
            with self.assertRaisesRegex(ValueError, "preflight error"):
                self.invoke_main()
            prepare.assert_not_called()
        self.assertEqual(self.project.read_text(), self.original)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.revision)

    def test_publish_failure_retries_same_version_then_next_success_increments(self):
        with patch.object(release, "Storage"), patch.object(release, "prepare_release", return_value=self.root / "manifest.json") as prepare:
            with patch.object(release, "publish", side_effect=ValueError("synthetic upload failure")):
                with self.assertRaisesRegex(ValueError, "upload failure"):
                    self.invoke_main()
            first = prepare.call_args.args[2:]
            self.assertEqual(first[0], "0.0.10")
            self.assertTrue(release.pending_path(self.root, self.args.arch).exists())
            with patch.object(release, "publish"):
                self.invoke_main()
                self.assertEqual(prepare.call_args.args[2:], first)
                self.assertFalse(release.pending_path(self.root, self.args.arch).exists())
                self.invoke_main()
            self.assertEqual(prepare.call_args.args[2], "0.0.11")
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "3")

    def test_second_architecture_can_publish_same_version_with_no_bump(self):
        first = self.prepare()
        self.args.arch = "x86_64"
        self.args.no_bump = True
        self.assertEqual(self.prepare(), first)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")


if __name__ == "__main__":
    unittest.main()
