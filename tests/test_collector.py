import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from rebecca_pet.collector import ParentGuard, atomic_write, demo_document, main, output_path


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
