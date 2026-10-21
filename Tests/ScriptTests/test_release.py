import contextlib
import base64
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
    def feed_content(self, version, build):
        content = dict(self.content, version=version, build=build)
        content["assets"] = {f"SI-{version}-universal-update.zip": self.content["assets"][self.update.name]}
        return content

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
        self.content["build"] = release.project_build(ROOT)
        self.content["update_signature"] = base64.b64encode(bytes(64)).decode()
        self.update = self.directory / "SI-0.1.0-universal-update.zip"
        self.update.write_bytes(b"synthetic app update")
        self.content["assets"] = {self.image.name: {"sha256": release.digest(self.image).hexdigest(),
                                                "size": self.image.stat().st_size, "url": "synthetic"},
                                  self.update.name: {"sha256": release.digest(self.update).hexdigest(),
                                                     "size": self.update.stat().st_size, "url": "synthetic-update"}}
        self.manifest = self.directory / "manifest.json"
        self.manifest.write_text(json.dumps(self.content))
        self.feed = "si/channels/mac/stable-universal.xml"

    def test_invalid_or_mismatched_signing_identities_are_rejected(self):
        with patch.dict("os.environ", {}, clear=True), contextlib.redirect_stderr(io.StringIO()):
            for options in (["--sign", "-"], ["--installer-sign", IDENTITY],
                            ["--sign", IDENTITY, "--installer-sign", "Developer ID Installer: Other (1234567890)"]):
                with self.subTest(options=options), self.assertRaises(SystemExit):
                    release.arguments(options)

    def test_application_uses_codesigning_policy_before_matching_installer(self):
        application_output = f'1) B "{IDENTITY}"\n4) D "Apple Development: Other"\n'
        basic_output = (f'1) B "{IDENTITY}"\n2) C "{INSTALLER_IDENTITY}"\n'
                        '3) D "Developer ID Application: Obsolete (1234567890)"\n'
                        '4) E "Developer ID Installer: Obsolete (1234567890)"\n')
        with patch.dict("os.environ", {}, clear=True):
            args = release.arguments(["--publish", "--arch", "arm64"])
        outputs = [release.subprocess.CompletedProcess([], 0, text, "") for text in (application_output, basic_output)]
        with patch.object(release.subprocess, "run", side_effect=outputs) as run:
            release.resolve_signing(args)
            self.assertEqual(run.call_args_list[0].args[0], ["security", "find-identity", "-v", "-p", "codesigning"])
            self.assertEqual(run.call_args_list[1].args[0], ["security", "find-identity", "-v", "-p", "basic"])
        self.assertEqual((args.sign, args.installer_sign), (IDENTITY, INSTALLER_IDENTITY))
        self.assertEqual(args.notarize_profile, "caterm-notary")

    def test_missing_installer_never_selects_another_teams_basic_only_pair(self):
        with patch.dict("os.environ", {}, clear=True):
            args = release.arguments(["--publish"])
        outputs = [f'"{IDENTITY}"\n',
                   '"Developer ID Application: Obsolete (1234567890)"\n'
                   '"Developer ID Installer: Obsolete (1234567890)"\n']
        responses = [release.subprocess.CompletedProcess([], 0, text, "") for text in outputs]
        with patch.object(release.subprocess, "run", side_effect=responses):
            with self.assertRaisesRegex(ValueError, "No valid Developer ID Installer identity for signing team ABCDEFGHIJ"):
                release.resolve_signing(args)
        self.assertEqual(args.sign, IDENTITY)
        self.assertIsNone(args.installer_sign)

    def test_missing_or_ambiguous_keychain_pairs_stop_before_build(self):
        with patch.dict("os.environ", {}, clear=True):
            for output in ("0 valid identities found", f'"{IDENTITY}"\n',
                           f'"{IDENTITY}"\n"{INSTALLER_IDENTITY}"\n'
                           '"Developer ID Application: Other (1234567890)"\n'
                           '"Developer ID Installer: Other (1234567890)"\n'):
                args = release.arguments(["--publish"])
                with patch.object(release.subprocess, "run", return_value=release.subprocess.CompletedProcess([], 0, output, "")):
                    with self.assertRaises(ValueError):
                        release.resolve_signing(args)

    def test_explicit_signer_filters_discovery_and_preserves_profile(self):
        with patch.dict("os.environ", {}, clear=True):
            args = release.arguments(["--publish", "--sign", IDENTITY, "--notarize-profile", "chosen-notary"])
        output = f'"{INSTALLER_IDENTITY}"\n"Developer ID Installer: Other (1234567890)"\n'
        with patch.object(release.subprocess, "run", return_value=release.subprocess.CompletedProcess([], 0, output, "")):
            release.resolve_signing(args)
        self.assertEqual(args.installer_sign, INSTALLER_IDENTITY)
        self.assertEqual(args.notarize_profile, "chosen-notary")

    def test_local_unsigned_packaging_does_not_read_keychain_or_enable_notarization(self):
        with patch.dict("os.environ", {}, clear=True):
            args = release.arguments([])
        with patch.object(release.subprocess, "run") as run:
            release.resolve_signing(args)
            run.assert_not_called()
        self.assertIsNone(args.sign)
        self.assertIsNone(args.notarize_profile)

    def test_explicit_pair_needs_no_keychain_access(self):
        with patch.object(release.subprocess, "run") as run:
            release.resolve_signing(self.args)
            run.assert_not_called()
        self.assertEqual(self.args.notarize_profile, "test-notary")

    def test_keychain_access_failure_never_falls_back_to_unsigned_publication(self):
        with patch.dict("os.environ", {}, clear=True):
            args = release.arguments(["--publish"])
        with patch.object(release.subprocess, "run", side_effect=FileNotFoundError("security")):
            with self.assertRaisesRegex(ValueError, "Cannot inspect Keychain"):
                release.resolve_signing(args)
        self.assertIsNone(args.sign)

    def test_prefix_cannot_escape_product_namespace(self):
        for prefix in ("", "../caterm", "/si", "si/", "si/../../channels"):
            with self.subTest(prefix=prefix), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                release.arguments(["--prefix", prefix])

    def test_channel_changes_only_after_all_public_artifacts_pass(self):
        checked = []

        def verify(args, key, expected):
            checked.append(key)
            self.assertIn(key, self.storage.objects)
            if key not in (self.channel, self.feed):
                self.assertNotIn(self.channel, self.storage.objects)
            if key != self.feed:
                self.assertNotIn(self.feed, self.storage.objects)

        with patch.object(release, "verify_public", side_effect=verify):
            release.publish(self.args, self.manifest, self.storage)
        self.assertEqual(checked[-2:], [self.channel, self.feed])
        self.assertEqual(self.storage.writes[-1], (self.feed, ("--if-none-match", "*")))

    def test_failed_anonymous_download_leaves_channel_unchanged(self):
        with patch.object(release, "verify_public", side_effect=ValueError("bad checksum")):
            with self.assertRaisesRegex(ValueError, "bad checksum"):
                release.publish(self.args, self.manifest, self.storage)
        self.assertNotIn(self.channel, self.storage.objects)
        self.assertNotIn(self.feed, self.storage.objects)

    def test_appcast_uses_build_counter_and_app_archive_instead_of_installer(self):
        xml = release.ET.fromstring(release.appcast_bytes(dict(self.content, build=42)))
        item = xml.find("./channel/item")
        namespace = release.SPARKLE_NAMESPACE
        self.assertEqual(item.findtext(f"{{{namespace}}}version"), "42")
        self.assertEqual(item.findtext(f"{{{namespace}}}shortVersionString"), "0.1.0")
        self.assertEqual(item.findtext(f"{{{namespace}}}minimumSystemVersion"), "14.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "synthetic-update")
        self.assertEqual(enclosure.get("length"), str(self.update.stat().st_size))
        self.assertEqual(enclosure.get(f"{{{namespace}}}edSignature"), self.content["update_signature"])
        for invalid in (dict(self.content, build=0), dict(self.content, update_signature="invalid")):
            with self.assertRaises(ValueError):
                release.appcast_bytes(invalid)

    def test_newer_conflicting_and_malformed_feeds_prevent_uploads(self):
        for content in (self.feed_content("0.2.0", self.content["build"] + 1),
                        dict(self.content, update_signature=base64.b64encode(bytes([1]) * 64).decode())):
            self.storage.objects[self.feed] = release.appcast_bytes(content)
            with self.assertRaises(ValueError):
                release.publish(self.args, self.manifest, self.storage)
            self.assertEqual(self.storage.writes, [])
        self.storage.objects[self.feed] = b"invalid XML"
        with self.assertRaisesRegex(ValueError, "Invalid existing Sparkle feed"):
            release.publish(self.args, self.manifest, self.storage)

    def test_feed_uses_etag_and_identical_retry_makes_no_channel_writes(self):
        old = self.feed_content("0.0.9", 1)
        self.content["build"] = 2
        self.manifest.write_text(json.dumps(self.content))
        self.storage.objects[self.feed] = release.appcast_bytes(old)
        with patch.object(release, "verify_public"):
            release.publish(self.args, self.manifest, self.storage)
        self.assertEqual(self.storage.writes[-1], (self.feed, ("--if-match", "original-etag")))
        self.storage.writes.clear()
        with patch.object(release, "verify_public"):
            release.publish(self.args, self.manifest, self.storage)
        self.assertFalse(any(key in (self.channel, self.feed) for key, _ in self.storage.writes))

    def test_concurrent_feed_advance_is_not_overwritten(self):
        newer = self.feed_content("0.2.0", self.content["build"] + 1)

        def competing_release(args, key, expected):
            if key == self.channel:
                self.storage.objects[self.feed] = release.appcast_bytes(newer)

        with patch.object(release, "verify_public", side_effect=competing_release):
            with self.assertRaisesRegex(ValueError, "downgrade"):
                release.publish(self.args, self.manifest, self.storage)
        self.assertFalse(any(key == self.feed for key, _ in self.storage.writes))

    def test_sparkle_key_mismatch_stops_before_signing(self):
        destination = self.directory / ".build" / f"Sparkle-{release.SPARKLE_VERSION}"
        (destination / "bin").mkdir(parents=True)
        (destination / "distribution.tar.xz").write_bytes(b"synthetic pinned tools")
        for name in ("generate_keys", "sign_update"):
            (destination / "bin" / name).touch()
        info = self.directory / "mac/Support/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(release.plistlib.dumps({"SUPublicEDKey": base64.b64encode(bytes(32)).decode()}))
        with patch.object(release, "SPARKLE_SHA256", release.digest(destination / "distribution.tar.xz").hexdigest()), \
                patch.object(release.subprocess, "check_output", return_value="different-key"), \
                patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "does not match"):
                release.sparkle_tools(self.directory)
            run.assert_not_called()

    def test_nested_signing_reaches_helpers_before_framework_and_app(self):
        with patch.object(release, "run") as run:
            release.sign_nested_code(self.directory / "SI.app", ["codesign", "--sign", IDENTITY], True)
        names = [call.args[0][-1].name for call in run.call_args_list]
        self.assertEqual(names, ["Installer.xpc", "Downloader.xpc", "Autoupdate", "Updater.app", "Sparkle.framework", "SI.app"])

    def test_replacement_uses_etag_and_rechecks_competing_release(self):
        old = dict(self.content, version="0.0.9")
        self.storage.objects[self.channel] = json.dumps(old).encode()
        with patch.object(release, "verify_public"):
            release.publish(self.args, self.manifest, self.storage)
        self.assertIn((self.channel, ("--if-match", "original-etag")), self.storage.writes)

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
                                  for path in (self.image, checksum, source, self.update)}
        self.manifest.write_text(json.dumps(self.content))
        with patch.object(release, "package") as package, patch.object(release, "run") as run, \
                patch.object(release, "sparkle_tools", return_value=self.directory):
            result = release.prepare_release(self.args, ROOT, "0.1.0", "a" * 40, self.directory)
            self.assertEqual(result, self.manifest)
            package.assert_not_called()
            self.assertEqual(run.call_count, 3)  # EdDSA, code signature and stapled ticket checks remain mandatory.
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
                    "CFBundleIdentifier": "com.caterm.inputmethod.si", "CFBundleShortVersionString": "0.1.0",
                    "CFBundleVersion": str(release.project_build(ROOT)),
                    "SUFeedURL": "https://downloads.caterm.com/si/channels/mac/stable-universal.xml"}):
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
