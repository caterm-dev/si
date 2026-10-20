import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "scripts/installer"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="si installer ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user_directory = self.root / "User"
        self.user_directory.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.executable(self.bin / "id", '#!/bin/bash\nprintf "%s\\n" "${SI_TEST_UID:-501}"\n')
        self.executable(self.bin / "pgrep", '#!/bin/bash\n[[ "$*" == "-x SI" ]] || exit 3\nexit "${SI_TEST_PROCESS_STATUS:-1}"\n')
        self.script = self.root / "preinstall"
        # Redirect the copied fixture to a private directory without changing the process HOME.
        fixture = (INSTALLER / "preinstall").read_text().replace("$HOME", "$SI_TEST_HOME").replace("${HOME", "${SI_TEST_HOME")
        self.executable(self.script, fixture)
        self.destination = self.user_directory / "Library/Input Methods/SI.app"

    def executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_preinstall(self, **environment):
        return subprocess.run([str(self.script)], env={**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                              "SI_TEST_HOME": str(self.user_directory), **environment},
                              text=True, capture_output=True, timeout=10)

    def existing_app(self, identifier="com.caterm.inputmethod.si"):
        contents = self.destination / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        (contents / "synthetic").write_bytes(b"previous app bytes")

    def test_distribution_requests_logout_only_for_current_user(self):
        distribution = ET.parse(INSTALLER / "Distribution.xml").getroot()
        self.assertEqual(distribution.find("domains").attrib, {
            "enable_anywhere": "false", "enable_currentUserHome": "true", "enable_localSystem": "false"})
        package = distribution.find("pkg-ref")
        self.assertEqual(package.get("onConclusion"), "RequireLogout")
        self.assertEqual(distribution.find("conclusion").get("file"), "Conclusion.txt")
        components = plistlib.loads((INSTALLER / "components.plist").read_bytes())
        self.assertFalse(components[0]["BundleIsRelocatable"])
        self.assertFalse(components[0]["BundleHasStrictIdentifier"])
        self.assertEqual(components[0]["BundleOverwriteAction"], "upgrade")

    def test_fresh_install_preflight_does_not_change_user_files(self):
        result = self.run_preinstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.user_directory.iterdir()), [])

    def test_running_process_or_query_error_prevents_backup_and_replacement(self):
        self.existing_app()
        for status in ("0", "2"):
            with self.subTest(status=status):
                result = self.run_preinstall(SI_TEST_PROCESS_STATUS=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.user_directory / "Library/Application Support").exists())
                self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"previous app bytes")

    def test_upgrade_backs_up_current_or_legacy_app_without_removing_it(self):
        for identifier in ("com.caterm.inputmethod.si", "com.caterm.si"):
            with self.subTest(identifier=identifier):
                if not self.destination.exists():
                    self.existing_app(identifier)
                else:
                    (self.destination / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
                result = self.run_preinstall()
                self.assertEqual(result.returncode, 0, result.stderr)
                backups = list((self.user_directory / "Library/Application Support/SI/Backups").glob("Installer.*/SI.app"))
                self.assertTrue(any((app / "Contents/Info.plist").read_bytes() ==
                                    (self.destination / "Contents/Info.plist").read_bytes() for app in backups))
                self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"previous app bytes")

    def test_other_bundle_root_execution_or_symlink_is_rejected(self):
        self.existing_app("org.example.other")
        self.assertNotEqual(self.run_preinstall().returncode, 0)
        self.assertNotEqual(self.run_preinstall(SI_TEST_UID="0").returncode, 0)
        link = self.destination.with_name("saved-app")
        self.destination.rename(link)
        self.destination.symlink_to(link)
        self.assertNotEqual(self.run_preinstall().returncode, 0)
        self.assertFalse((self.user_directory / "Library/Application Support").exists())

    def test_restarted_process_after_backup_stops_installation(self):
        self.existing_app()
        self.executable(self.bin / "pgrep", '''#!/bin/bash
if [[ -e "$SI_TEST_MARKER" ]]; then exit 0; fi
touch "$SI_TEST_MARKER"
exit 1
''')
        result = self.run_preinstall(SI_TEST_MARKER=str(self.root / "queried"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SI is running", result.stderr)
        self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"previous app bytes")

    def test_backup_directory_error_stops_upgrade_without_removing_app(self):
        self.existing_app()
        directory = self.user_directory / "Library/Application Support/SI"
        directory.mkdir(parents=True)
        (directory / "Backups").write_text("synthetic file blocking the directory")
        result = self.run_preinstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/synthetic").read_bytes(), b"previous app bytes")


if __name__ == "__main__":
    unittest.main()
