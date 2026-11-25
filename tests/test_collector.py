import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from rebecca_pet.collector import Diagnostics, ParentGuard, atomic_write, demo_document, main, output_path


ROOT = Path(__file__).resolve().parents[1]
TEST_TEMP = ROOT / "tmp" / "tests"


class CollectorTests(unittest.TestCase):
    def setUp(self):
        TEST_TEMP.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="collector-", dir=TEST_TEMP)
        self.path = Path(self.temporary.name) / "state.json"

    def tearDown(self):
        self.temporary.cleanup()

    def test_atomic_write_produces_complete_unicode_json(self):
        document = demo_document(1)
        atomic_write(self.path, document)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8")), document)
        self.assertEqual(list(self.path.parent.glob("*.tmp")), [])

    def test_failed_replace_preserves_previous_snapshot_and_cleans_temp(self):
        atomic_write(self.path, {"old": True})
        with patch("rebecca_pet.collector.os.replace", side_effect=PermissionError("busy")):
            with self.assertRaises(PermissionError):
                atomic_write(self.path, {"new": True}, retries=1)
        self.assertEqual(json.loads(self.path.read_text()), {"old": True})
        self.assertEqual(list(self.path.parent.glob("*.tmp")), [])

    def test_temporary_windows_sharing_conflict_is_retried(self):
        actual_replace = os.replace
        calls = []
        def delayed_replace(source, target):
            calls.append(True)
            if len(calls) == 1:
                raise PermissionError("sharing conflict")
            actual_replace(source, target)
        with patch("rebecca_pet.collector.os.replace", side_effect=delayed_replace):
            atomic_write(self.path, {"ok": True})
        self.assertEqual(len(calls), 2)
        self.assertTrue(json.loads(self.path.read_text())["ok"])

    def test_c_drive_paths_rejected_lexically(self):
        for value in ("C:\\temp\\state.json", "c:/state.json", "C:state.json",
                      r"\\?\C:\temp\state.json", r"\\.\C:\temp\state.json",
                      "//?/C:/temp/state.json", r"\\?\GLOBALROOT\Device\HarddiskVolume1\state.json"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                output_path(value)

    def test_oversized_output_does_not_replace_existing_file(self):
        atomic_write(self.path, {"old": True})
        with self.assertRaises(ValueError):
            atomic_write(self.path, {"large": "x" * 70_000})
        self.assertEqual(json.loads(self.path.read_text()), {"old": True})

    def test_demo_once_never_constructs_adapter(self):
        with patch("rebecca_pet.collector.SQLiteAdapter", side_effect=AssertionError("T3 read")):
            self.assertEqual(main(["--demo", "--once", "--output", str(self.path)]), 0)
        document = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(document["mode"], "demo")
        self.assertEqual(document["source"]["kind"], "demo")

    def test_monitor_recovers_after_temporary_write_failure(self):
        actual_write = atomic_write
        attempts = []
        clock = [0.0]
        def write(path, document):
            attempts.append(clock[0])
            if len(attempts) == 2:
                raise PermissionError(32, "secret filename must not be logged")
            actual_write(path, document)
        def wait(seconds):
            clock[0] += seconds
        with patch("rebecca_pet.collector.atomic_write", side_effect=write), \
             patch("rebecca_pet.collector.ParentGuard.alive", side_effect=lambda: len(attempts) < 3), \
             patch("rebecca_pet.collector.time.monotonic", side_effect=lambda: clock[0]), \
             patch("rebecca_pet.collector.threading.Event.wait", side_effect=wait):
            self.assertEqual(main(["--demo", "--poll", "0.2", "--output", str(self.path)]), 0)
        self.assertEqual(len(attempts), 3)
        self.assertGreaterEqual(attempts[2] - attempts[1], 0.4)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8"))["mode"], "demo")
        log = self.path.with_suffix(".log").read_text(encoding="utf-8")
        self.assertIn("snapshot_write_failed", log)
        self.assertIn("snapshot_write_recovered", log)
        self.assertNotIn("secret filename", log)

    def test_owned_monitor_observes_ui_and_immediate_launcher(self):
        ui, launcher = Mock(), Mock()
        ui.alive.return_value = True
        launcher.alive.return_value = False
        with patch("rebecca_pet.collector.ParentGuard", side_effect=[ui, launcher]) as guard, \
             patch("rebecca_pet.collector.os.getppid", return_value=333):
            self.assertEqual(main(["--demo", "--once", "--parent-pid", "222", "--output", str(self.path)]), 0)
        self.assertEqual([call.args[0] for call in guard.call_args_list], [222, 333])
        self.assertFalse(self.path.exists())
        ui.close.assert_called_once()
        launcher.close.assert_called_once()

    def test_unavailable_launcher_closes_already_opened_ui_guard(self):
        ui = Mock()
        with patch("rebecca_pet.collector.ParentGuard", side_effect=[ui, ValueError("gone")]), \
             patch("rebecca_pet.collector.os.getppid", return_value=333), \
             patch("rebecca_pet.collector.sys.stderr", None):
            self.assertEqual(main(["--demo", "--once", "--parent-pid", "222", "--output", str(self.path)]), 2)
        ui.close.assert_called_once()
        self.assertFalse(self.path.exists())

    def test_persistent_write_failure_backs_off_and_logs_once(self):
        attempts = []
        clock = [0.0]
        def write(*_):
            attempts.append(clock[0])
            raise PermissionError(32, "busy")
        def wait(seconds):
            clock[0] += seconds
        with patch("rebecca_pet.collector.atomic_write", side_effect=write), \
             patch("rebecca_pet.collector.ParentGuard.alive", side_effect=lambda: len(attempts) < 4), \
             patch("rebecca_pet.collector.time.monotonic", side_effect=lambda: clock[0]), \
             patch("rebecca_pet.collector.threading.Event.wait", side_effect=wait):
            self.assertEqual(main(["--demo", "--poll", "0.2", "--output", str(self.path)]), 0)
        for actual, expected in zip(attempts, (0, 0.4, 1.2, 2.8)):
            self.assertAlmostEqual(actual, expected)
        self.assertFalse(self.path.exists())
        log = self.path.with_suffix(".log").read_text(encoding="utf-8")
        self.assertEqual(log.count("snapshot_write_failed"), 1)

    def test_once_write_failure_still_returns_error_without_stderr(self):
        with patch("rebecca_pet.collector.atomic_write", side_effect=PermissionError("private data")), \
             patch("rebecca_pet.collector.sys.stderr", None):
            self.assertEqual(main(["--demo", "--once", "--output", str(self.path)]), 2)
        self.assertFalse(self.path.exists())
        self.assertNotIn("private data", self.path.with_suffix(".log").read_text())

    def test_diagnostics_rotate_and_never_include_exception_messages(self):
        diagnostic = Diagnostics(self.path)
        with patch("rebecca_pet.collector.MAX_LOG_BYTES", 512):
            for _ in range(20):
                diagnostic.write("snapshot_write_failed", OSError(5, "TOP_SECRET"))
        backup = diagnostic.path.with_suffix(".log.1")
        self.assertTrue(backup.exists())
        for path in (diagnostic.path, backup):
            self.assertLessEqual(path.stat().st_size, 512)
            self.assertNotIn("TOP_SECRET", path.read_text())
        self.assertEqual(len(list(self.path.parent.glob("*.log*"))), 2)

    def test_diagnostic_write_failure_does_not_stop_monitor(self):
        with patch("pathlib.Path.open", side_effect=PermissionError("log locked")):
            Diagnostics(self.path).write("started")
        self.assertFalse(self.path.with_suffix(".log").exists())

    @unittest.skipUnless(os.name == "nt", "Windows file-sharing semantics")
    def test_process_survives_real_windows_file_lock_and_recovers(self):
        import ctypes
        from ctypes import wintypes
        atomic_write(self.path, {"before_lock": True})
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        # Permit reads, but deny replacement for longer than atomic_write's
        # 120 ms retry budget. This reproduces the original permanent exit.
        handle = kernel.CreateFileW(str(self.path), 0x80000000, 1, None, 3, 128, None)
        self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(ROOT / "src")
        process = None
        try:
            process = subprocess.Popen([
                sys.executable, "-B", "-m", "rebecca_pet.collector", "--demo", "--poll", "0.2",
                "--output", str(self.path), "--parent-pid", str(os.getpid()),
            ], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 5
            log = self.path.with_suffix(".log")
            while time.monotonic() < deadline:
                if log.exists() and "snapshot_write_failed" in log.read_text():
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.02)
            self.assertIn("snapshot_write_failed", log.read_text())
            self.assertIsNone(process.poll())
            self.assertEqual(json.loads(self.path.read_text()), {"before_lock": True})
            kernel.CloseHandle(handle)
            handle = None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if "snapshot_write_recovered" in log.read_text():
                    break
                time.sleep(0.02)
            self.assertIn("snapshot_write_recovered", log.read_text())
            self.assertEqual(json.loads(self.path.read_text(encoding="utf-8"))["mode"], "demo")
            self.assertIsNone(process.poll())
        finally:
            if handle is not None:
                kernel.CloseHandle(handle)
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)

    def test_all_demo_states_follow_ui_contract(self):
        states = set()
        for step in range(8):
            document = demo_document(step)
            states.add(document["state"])
            self.assertEqual(document["schema_version"], 1)
            self.assertEqual(set(document["counts"]), {"working", "waiting_user", "pending", "failed"})
            self.assertTrue(all(type(count) is int and count >= 0 for count in document["counts"].values()))
            self.assertIsInstance(document["source"]["version"], str)
            self.assertTrue(document["observed_at"].endswith("Z"))
        self.assertEqual(len(states), 8)

    def test_live_missing_home_writes_explicit_offline(self):
        code = main(["--once", "--t3-home", str(self.path.parent / "missing"), "--output", str(self.path)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8"))["state"], "offline")

    def test_parent_handle_tracks_exact_process_exit(self):
        child = subprocess.Popen([sys.executable, "-B", "-c", "import time; time.sleep(10)"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        guard = ParentGuard(child.pid)
        try:
            self.assertTrue(guard.alive())
            child.terminate()
            child.wait(timeout=3)
            self.assertFalse(guard.alive())
        finally:
            guard.close()
            if child.poll() is None:
                child.kill()
                child.wait(timeout=3)

    def test_collector_process_exits_when_parent_dies(self):
        parent = subprocess.Popen([sys.executable, "-B", "-c", "import time; time.sleep(10)"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(ROOT / "src")
        collector = subprocess.Popen([
            sys.executable, "-B", "-m", "rebecca_pet.collector", "--demo", "--poll", "0.2",
            "--output", str(self.path), "--parent-pid", str(parent.pid),
        ], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 3
            while not self.path.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.path.exists())
            parent.terminate()
            parent.wait(timeout=3)
            self.assertEqual(collector.wait(timeout=3), 0)
        finally:
            for process in (collector, parent):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
