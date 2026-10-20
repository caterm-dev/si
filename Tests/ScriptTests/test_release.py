import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("si_release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
IDENTITY = "Developer ID Application: Example (ABCDEFGHIJ)"
INSTALLER_IDENTITY = "Developer ID Installer: Example (ABCDEFGHIJ)"


class MemoryStorage:
    def __init__(self):
        self.objects = {}
        self.writes = []

    def get(self, key, destination):
        if key not in self.objects:
            return None
        destination.write_bytes(self.objects[key])
        return {"ETag": "original-etag"}

    def put(self, key, path, content_type, cache, condition):
        self.writes.append((key, condition))
        self.objects[key] = path.read_bytes()

    def immutable(self, key, path, content_type):
        self.put(key, path, content_type, release.IMMUTABLE_CACHE, ("--if-none-match", "*"))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="si release ")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.args = release.arguments(["--publish", "--sign", IDENTITY, "--installer-sign", INSTALLER_IDENTITY,
                                       "--notarize-profile", "test-notary"])
        self.channel = "si/channels/mac/stable-universal.json"
        self.storage = MemoryStorage()
        self.image = self.directory / "SI-0.1.0-universal.dmg"
        self.image.write_bytes(b"synthetic disk image")
        self.content = release.metadata(self.args, "0.1.0", "a" * 40)
        self.content["assets"] = {self.image.name: {"sha256": release.digest(self.image).hexdigest(),
                                                "size": self.image.stat().st_size, "url": "synthetic"}}
        self.manifest = self.directory / "manifest.json"
        self.manifest.write_text(json.dumps(self.content))

    def test_publication_requires_signing_and_notarization(self):
        with patch.dict("os.environ", {}, clear=True), contextlib.redirect_stderr(io.StringIO()):
            for options in (["--publish"], ["--publish", "--sign", IDENTITY],
                            ["--notarize-profile", "test"], ["--sign", "-"],
                            ["--publish", "--sign", IDENTITY, "--notarize-profile", "test"],
                            ["--sign", IDENTITY, "--installer-sign", "Developer ID Installer: Other (1234567890)"]):
                with self.subTest(options=options), self.assertRaises(SystemExit):
                    release.arguments(options)

    def test_prefix_cannot_escape_product_namespace(self):
        for prefix in ("", "../caterm", "/si", "si/", "si/../../channels"):
            with self.subTest(prefix=prefix), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                release.arguments(["--prefix", prefix])

    def test_channel_changes_only_after_all_public_artifacts_pass(self):
        checked = []

        def verify(args, key, expected):
            checked.append(key)
            self.assertIn(key, self.storage.objects)
            if key != self.channel:
                self.assertNotIn(self.channel, self.storage.objects)

        with patch.object(release, "verify_public", side_effect=verify):
            release.publish(self.args, self.manifest, self.storage)
        self.assertEqual(checked[-1], self.channel)
        self.assertEqual(self.storage.writes[-1], (self.channel, ("--if-none-match", "*")))

    def test_failed_anonymous_download_leaves_channel_unchanged(self):
        with patch.object(release, "verify_public", side_effect=ValueError("bad checksum")):
            with self.assertRaisesRegex(ValueError, "bad checksum"):
                release.publish(self.args, self.manifest, self.storage)
        self.assertNotIn(self.channel, self.storage.objects)

    def test_replacement_uses_etag_and_rechecks_competing_release(self):
        old = dict(self.content, version="0.0.9")
        self.storage.objects[self.channel] = json.dumps(old).encode()
        with patch.object(release, "verify_public"):
            release.publish(self.args, self.manifest, self.storage)
        self.assertEqual(self.storage.writes[-1], (self.channel, ("--if-match", "original-etag")))

        self.storage = MemoryStorage()

        def advance_channel(*args):
            self.storage.objects[self.channel] = json.dumps(dict(self.content, version="0.2.0")).encode()

        with patch.object(release, "verify_public", side_effect=advance_channel):
            with self.assertRaisesRegex(ValueError, "downgrade"):
                release.publish(self.args, self.manifest, self.storage)
        self.assertFalse(any(key == self.channel for key, _ in self.storage.writes))

    def test_conflicting_or_newer_channel_prevents_upload(self):
        for current in (dict(self.content, version="0.2.0"), dict(self.content, revision="b" * 40)):
            self.storage.objects[self.channel] = json.dumps(current).encode()
            with self.assertRaises(ValueError):
                release.publish(self.args, self.manifest, self.storage)
            self.assertEqual(self.storage.writes, [])

    def test_storage_does_not_treat_authentication_error_as_missing_object(self):
        storage = release.Storage(self.args)
        for message, missing in [("(NoSuchKey)", True), ("(AccessDenied)", False), ("timeout", False)]:
            result = release.subprocess.CompletedProcess([], 1, "", message)
            with patch.object(release.subprocess, "run", return_value=result):
                if missing:
                    self.assertIsNone(storage.get("si/missing", self.directory / "missing"))
                else:
                    with self.assertRaises(ValueError):
                        storage.get("si/missing", self.directory / "missing")

    def test_immutable_object_conflict_prevents_put(self):
        storage = release.Storage(self.args)

        def existing(key, destination):
            destination.write_bytes(b"different bytes")
            return {"ETag": "existing"}

        with patch.object(storage, "get", side_effect=existing), patch.object(storage, "put") as put:
            with self.assertRaisesRegex(ValueError, "Published object differs"):
                storage.immutable("si/image.dmg", self.image, "application/x-apple-diskimage")
            put.assert_not_called()

    def test_dirty_checkout_blocks_publication(self):
        with patch.object(release, "git", return_value=" M README.md"):
            with self.assertRaisesRegex(ValueError, "checkout must be clean"):
                release.validate_checkout(ROOT, "0.1.0", "a" * 40)

    def test_cached_release_reuses_only_identical_files_and_destination(self):
        prefix = "si/releases/0.1.0/mac/universal"
        checksum = self.image.with_suffix(".dmg.sha256")
        checksum.write_text(f"{release.digest(self.image).hexdigest()}  {self.image.name}\n")
        source = self.directory / "SI-0.1.0-source.tar.gz"
        source.write_bytes(b"synthetic source")
        self.content["assets"] = {path.name: {"sha256": release.digest(path).hexdigest(),
                                             "size": path.stat().st_size,
                                             "url": f"{self.args.public_url}/{prefix}/{path.name}"}
                                  for path in (self.image, checksum, source)}
        self.manifest.write_text(json.dumps(self.content))
        with patch.object(release, "package") as package, patch.object(release, "run") as run:
            result = release.prepare_release(self.args, ROOT, "0.1.0", "a" * 40, self.directory)
            self.assertEqual(result, self.manifest)
            package.assert_not_called()
            self.assertEqual(run.call_count, 2)  # Signature and stapled ticket checks remain mandatory.
            self.image.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "artifact differs"):
                release.prepare_release(self.args, ROOT, "0.1.0", "a" * 40, self.directory)

    def test_public_download_must_match_bytes_and_origin(self):
        class Response(io.BytesIO):
            url = "https://downloads.caterm.com/si/image.dmg"

        with patch.object(release.urllib.request, "urlopen", return_value=Response(b"bad bytes")):
            with self.assertRaisesRegex(ValueError, "checksum differs"):
                release.verify_public(self.args, "si/image.dmg", release.digest(self.image).hexdigest())
        response = Response(b"irrelevant")
        response.url = "https://login.example.com/"
        with patch.object(release.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(ValueError, "redirect"):
                release.verify_public(self.args, "si/image.dmg", "irrelevant")

    def test_dry_run_never_builds_writes_or_uploads(self):
        with patch.object(release, "git", return_value="a" * 40), patch.object(release.subprocess, "run") as run:
            with contextlib.redirect_stdout(io.StringIO()):
                release.main(["--publish", "--sign", IDENTITY, "--installer-sign", INSTALLER_IDENTITY,
                              "--notarize-profile", "test-notary", "--dry-run",
                              "--output-dir", str(self.directory / "absent")])
            run.assert_not_called()
        self.assertFalse((self.directory / "absent").exists())

    def test_rejected_notarization_does_not_expose_final_image(self):
        output = self.directory / "failed"

        def command(args, dry=False, capture=False):
            if args[:3] == ["xcrun", "notarytool", "submit"]:
                return '{"status":"Invalid","id":"synthetic-id"}'
            return ""

        with patch.object(release, "run", side_effect=command), patch.object(release, "install_readme"), \
                patch.object(release.plistlib, "loads", return_value={
                    "CFBundleIdentifier": "com.caterm.inputmethod.si", "CFBundleShortVersionString": "0.1.0"}):
            # Emulate only the bundle metadata read and architecture query; no real build or Apple request.
            original = Path.read_bytes

            def read_bytes(path):
                return b"fixture" if path.name == "Info.plist" else original(path)

            def commands(args, dry=False, capture=False):
                return "arm64 x86_64" if args[0] == "lipo" else command(args, dry, capture)

            with patch.object(Path, "read_bytes", read_bytes), patch.object(release, "run", side_effect=commands):
                with self.assertRaisesRegex(ValueError, "Apple notarization failed"):
                    release.package(self.args, ROOT, "0.1.0", output)
        self.assertFalse((output / self.image.name).exists())
        self.assertEqual(list(output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
