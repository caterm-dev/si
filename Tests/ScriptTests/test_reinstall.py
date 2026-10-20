import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]


class ReinstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="si reinstall ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "reinstall.sh"
        shutil.copy2(REPOSITORY / "scripts/reinstall.sh", self.script)
        self.state_path = self.root / "state.json"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_executable(self.bin / "process-fixture", f"#!{sys.executable}\n" + '''
import json
import os
from pathlib import Path
import sys

path = Path(os.environ["SI_TEST_STATE"])
state = json.loads(path.read_text())
command = Path(sys.argv[0]).name
arguments = sys.argv[1:]
expected = ["-u", str(os.getuid()), "-x", "SI"]
if command == "pkill":
    expected = [arguments[0]] + expected
if arguments != expected:
    sys.exit(3)
if command == "pgrep":
    status = 2 if state.get("query_error") else (0 if state["running"] else 1)
else:
    signal = arguments[0]
    state["signals"].append(signal)
    status = state.get("signal_status", 0)
    if status == 1 or (status == 0 and signal == state.get("exit_on", "-TERM")):
        state["running"] = False
path.write_text(json.dumps(state))
sys.exit(status)
''')
        for command in ("pgrep", "pkill"):
            (self.bin / command).symlink_to("process-fixture")
        self.write_executable(self.bin / "sleep", "#!/bin/bash\nexit 0\n")
        self.write_executable(scripts / "install.sh", f"#!{sys.executable}\n" + '''
import json
import os
from pathlib import Path
import sys

path = Path(os.environ["SI_TEST_STATE"])
state = json.loads(path.read_text())
state["installed"] = sys.argv[1:]
path.write_text(json.dumps(state))
sys.exit(state.get("install_status", 0))
''')

    def write_executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, *arguments, **state):
        self.state_path.write_text(json.dumps({"running": True, "signals": [], **state}))
        environment = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                       "SI_TEST_STATE": str(self.state_path)}
        result = subprocess.run([str(self.script), *arguments], cwd=self.root,
                                env=environment, capture_output=True, text=True, timeout=30)
        return result, json.loads(self.state_path.read_text())

    def test_stopped_process_installs_release_without_signals(self):
        result, state = self.run_script(running=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["signals"], [])
        self.assertEqual(state["installed"], ["Release"])

    def test_graceful_stop_is_scoped_and_forwards_debug(self):
        result, state = self.run_script("Debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["signals"], ["-TERM"])
        self.assertFalse(state["running"])
        self.assertEqual(state["installed"], ["Debug"])

    def test_unresponsive_process_requires_kill_before_install(self):
        result, state = self.run_script(exit_on="-KILL")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["signals"], ["-TERM", "-KILL"])
        self.assertFalse(state["running"])
        self.assertEqual(state["installed"], ["Release"])

    def test_process_that_does_not_stay_stopped_prevents_install(self):
        result, state = self.run_script(exit_on="never")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["signals"], ["-TERM", "-KILL"])
        self.assertNotIn("installed", state)

    def test_process_check_error_prevents_signals_and_install(self):
        result, state = self.run_script(query_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["signals"], [])
        self.assertNotIn("installed", state)

    def test_signal_error_prevents_install(self):
        result, state = self.run_script(signal_status=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("installed", state)

    def test_exit_between_check_and_signal_is_harmless(self):
        result, state = self.run_script(signal_status=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["signals"], ["-TERM"])
        self.assertEqual(state["installed"], ["Release"])

    def test_invalid_arguments_and_help_do_not_stop_or_install(self):
        for arguments, status in [(("Other",), 2), (("Debug", "Release"), 2), (("--help",), 0)]:
            with self.subTest(arguments=arguments):
                result, state = self.run_script(*arguments)
                self.assertEqual(result.returncode, status)
                self.assertEqual(state["signals"], [])
                self.assertNotIn("installed", state)

    def test_installer_failure_propagates(self):
        result, state = self.run_script(install_status=7)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(state["installed"], ["Release"])


if __name__ == "__main__":
    unittest.main()
