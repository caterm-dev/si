import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "Developer ID Application: Synthetic Developer (AAAAAAAAAA)"
FINGERPRINT = "A" * 40
IDENTITIES = f'  1) {FINGERPRINT} "{IDENTITY}"\n  2) {"B" * 40} "Apple Development: Synthetic Developer (BBBBBBBBBB)"'


class LocalInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="si local install ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user_directory = self.root / "User"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "install.sh"
        # Exercise replacement with synthetic bundles; never build, sign or register SI.
        fixture = (ROOT / "scripts/install.sh").read_text().replace("$HOME", "$SI_TEST_HOME")
        fixture = fixture.replace("/usr/bin/codesign", '"' + str(self.bin / "codesign") + '"')
        self.executable(self.script, fixture)
        self.executable(scripts / "build.sh", "#!/bin/bash\nexit 0\n")
        self.signing_log = self.root / "signing.jsonl"
        self.executable(self.bin / "codesign", f"#!{sys.executable}\n" + '''
import json
import os
import sys
with open(os.environ["SI_TEST_SIGNING_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
sys.exit(int(os.environ.get("SI_TEST_SIGNING_STATUS", "0")))
''')
        self.executable(self.bin / "security", '''#!/bin/bash
[[ "$*" == "find-identity -v -p codesigning" ]] || exit 3
printf '%s\\n' "$SI_TEST_IDENTITIES"
exit "${SI_TEST_KEYCHAIN_STATUS:-0}"
''')
        self.executable(self.bin / "xcrun", "#!/bin/bash\nexit 0\n")
        self.executable(self.bin / "pgrep", '#!/bin/bash\nexit "${SI_TEST_PROCESS_STATUS:-1}"\n')
        self.executable(self.bin / "mv", '''#!/bin/bash
if [[ "${SI_TEST_FAIL_REPLACEMENT:-0}" == 1 && "$1" == */.si-install.*/SI.app ]]; then
    exit 1
fi
if [[ "${SI_TEST_FAIL_ROLLBACK:-0}" == 1 && "$1" == */Previous.app ]]; then
    exit 1
fi
exec /bin/mv "$@"
''')
        self.destination = self.user_directory / "Library/Input Methods/SI.app"
        self.source = self.root / ".build/xcode/Build/Products/Release/SI.app"
        self.app(self.source, b"new app")

    def executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def app(self, path, content, identifier="com.caterm.inputmethod.si"):
        contents = path / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        (contents / "synthetic").write_bytes(content)

    def run_install(self, expect_recovery=False, **environment):
        result = subprocess.run([str(self.script)], env={
            **os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "SI_SIGN_IDENTITY": "", "SI_TEST_IDENTITIES": IDENTITIES,
            "SI_TEST_SIGNING_LOG": str(self.signing_log),
            "SI_TEST_HOME": str(self.user_directory), **environment,
        }, text=True, capture_output=True, timeout=10)
        self.assertFalse((self.user_directory / "Library/Application Support/SI/Backups").exists())
        if not expect_recovery:
            self.assertEqual(list(self.destination.parent.glob(".si-install.*")), [])
        return result

    def test_fresh_install_keeps_only_new_app(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"new app")

    def test_all_nested_code_uses_selected_developer_id(self):
        macos = self.source / "Contents/MacOS"
        macos.mkdir()
        (macos / "SI.debug.dylib").write_bytes(b"synthetic dylib")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [json.loads(line) for line in self.signing_log.read_text().splitlines()]
        signing = [command for command in commands if "--sign" in command]
        self.assertEqual(len(signing), 7)  # Debug dylib, five Sparkle items and SI.
        for command in signing:
            self.assertEqual(command[command.index("--sign") + 1], FINGERPRINT)
            self.assertIn("--timestamp=none", command)
        self.assertEqual(commands[-1][:3], ["--verify", "--deep", "--strict"])

    def test_missing_ambiguous_or_unavailable_identity_preserves_old_app(self):
        self.app(self.destination, b"old app")
        other = f'\n  3) {"C" * 40} "Developer ID Application: Other Developer (CCCCCCCCCC)"'
        cases = [
            {"SI_TEST_IDENTITIES": "0 valid identities found"},
            {"SI_TEST_IDENTITIES": IDENTITIES.splitlines()[1]},
            {"SI_TEST_IDENTITIES": IDENTITIES + other},
            {"SI_TEST_KEYCHAIN_STATUS": "1"},
            {"SI_SIGN_IDENTITY": "-"},
            {"SI_SIGN_IDENTITY": "Developer ID Application: Missing Developer (DDDDDDDDDD)"},
        ]
        for environment in cases:
            with self.subTest(environment=environment):
                result = self.run_install(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.signing_log.exists())
                self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"old app")

    def test_explicit_name_or_fingerprint_resolves_multiple_identities(self):
        other = f'\n  3) {"C" * 40} "Developer ID Application: Other Developer (CCCCCCCCCC)"'
        for selection in (IDENTITY, FINGERPRINT):
            with self.subTest(selection=selection):
                result = self.run_install(SI_SIGN_IDENTITY=selection, SI_TEST_IDENTITIES=IDENTITIES + other)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(IDENTITY, result.stdout)

    def test_signing_failure_preserves_old_app(self):
        self.app(self.destination, b"old app")
        result = self.run_install(SI_TEST_SIGNING_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"old app")

    def test_current_and_legacy_app_are_replaced_without_retained_backup(self):
        for identifier in ("com.caterm.inputmethod.si", "com.caterm.si"):
            with self.subTest(identifier=identifier):
                if not self.destination.exists():
                    self.app(self.destination, b"old app", identifier)
                else:
                    (self.destination / "Contents/Info.plist").write_bytes(
                        plistlib.dumps({"CFBundleIdentifier": identifier}))
                    (self.destination / "Contents/synthetic").write_bytes(b"old app")
                result = self.run_install()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"new app")

    def test_failed_replacement_restores_old_app(self):
        self.app(self.destination, b"old app")
        result = self.run_install(SI_TEST_FAIL_REPLACEMENT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"old app")

    def test_running_process_or_query_error_preserves_old_app(self):
        self.app(self.destination, b"old app")
        for status in ("0", "2"):
            with self.subTest(status=status):
                result = self.run_install(SI_TEST_PROCESS_STATUS=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"old app")

    def test_failed_rollback_preserves_old_app_for_recovery(self):
        self.app(self.destination, b"old app")
        result = self.run_install(expect_recovery=True,
                                  SI_TEST_FAIL_REPLACEMENT="1", SI_TEST_FAIL_ROLLBACK="1")
        self.assertNotEqual(result.returncode, 0)
        previous = list(self.destination.parent.glob(".si-install.*/Previous.app"))
        self.assertEqual(len(previous), 1)
        self.assertEqual((previous[0] / "Contents/synthetic").read_bytes(), b"old app")
        self.assertIn(str(previous[0]), result.stderr)


if __name__ == "__main__":
    unittest.main()
