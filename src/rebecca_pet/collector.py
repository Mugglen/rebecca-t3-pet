"""CLI process: bounded reads, pure reduction and atomic UI snapshots."""

from __future__ import annotations

import argparse
import ctypes
from datetime import datetime
import json
import math
import os
from pathlib import Path, PureWindowsPath
import signal
import sys
import tempfile
import threading
import time

from .adapter import SQLiteAdapter
from .state import Failure, Reducer, timestamp, utc_now


MAX_OUTPUT_BYTES = 64 * 1024
MAX_LOG_BYTES = 64 * 1024


class Diagnostics:
    """Best-effort bounded logs: fixed event names and error types/codes only."""

    def __init__(self, destination: Path) -> None:
        self.path = destination.with_suffix(".log")

    def write(self, event: str, error: Exception | None = None) -> None:
        entry = {"at": timestamp(utc_now()), "event": event, "pid": os.getpid()}
        if error is not None:
            entry["error_type"] = type(error).__name__
            for field in ("errno", "winerror"):
                code = getattr(error, field, None)
                if type(code) is int:
                    entry[field] = code
        body = (json.dumps(entry, separators=(",", ":")) + "\n").encode("utf-8")
        try:
            output_path(self.path)
            self.path.parent.mkdir(parents=True, exist_ok=True)
            if self.path.exists() and self.path.stat().st_size + len(body) > MAX_LOG_BYTES:
                os.replace(self.path, self.path.with_suffix(".log.1"))
            with self.path.open("ab") as stream:
                stream.write(body)
        except (OSError, ValueError):
            # A full/locked disk must not turn diagnostic logging into another
            # collector failure. Never fall back to the user profile or C:.
            pass


def report_error(message: str) -> None:
    """Hidden/pythonw processes may have no usable stderr."""
    try:
        if sys.stderr is not None:
            print(message, file=sys.stderr)
    except OSError:
        pass


def output_path(value: str | Path) -> Path:
    """Only normal D: paths on Windows; reject device namespaces and junction escapes."""
    def validate(candidate: str) -> None:
        normalized = candidate.replace("/", "\\")
        if normalized.startswith(("\\\\?\\", "\\\\.\\", "\\??\\")):
            raise ValueError("device-namespace output paths are not supported")
        drive = PureWindowsPath(candidate).drive.upper()
        if drive == "C:" or (os.name == "nt" and drive and drive != "D:"):
            raise ValueError("Windows output must be on D drive")
    validate(str(value))
    path = Path(value).expanduser().resolve()
    validate(str(path))
    if not path.name or path.is_dir():
        raise ValueError("output must be a file path")
    return path


def atomic_write(path: str | Path, value: dict, retries: int = 3) -> None:
    """Only our sibling temp file is removed on failure; previous JSON survives."""
    destination = output_path(path)
    body = (json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    if len(body) > MAX_OUTPUT_BYTES:
        raise ValueError("snapshot exceeds size limit")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, filename = tempfile.mkstemp(prefix=".rebecca-status-", suffix=".tmp", dir=destination.parent)
    temporary = Path(filename)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        for attempt in range(retries + 1):
            try:
                os.replace(temporary, destination)
                break
            except PermissionError:
                if attempt == retries:
                    raise
                time.sleep(0.02 * (attempt + 1))
    finally:
        temporary.unlink(missing_ok=True)


class ParentGuard:
    """Holds a Windows process handle so PID reuse cannot orphan the collector."""

    def __init__(self, pid: int | None) -> None:
        self.pid = pid
        self.handle = None
        self.kernel = None
        if pid is None:
            return
        if pid <= 0:
            raise ValueError("parent PID must be positive")
        if os.name == "nt":
            from ctypes import wintypes
            self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            self.kernel.OpenProcess.restype = wintypes.HANDLE
            self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            self.kernel.WaitForSingleObject.restype = wintypes.DWORD
            self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            self.kernel.CloseHandle.restype = wintypes.BOOL
            self.handle = self.kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
            if not self.handle:
                raise ValueError("parent process unavailable")

    def alive(self) -> bool:
        if self.pid is None:
            return True
        if self.kernel is not None:
            return self.kernel.WaitForSingleObject(self.handle, 0) == 0x00000102  # WAIT_TIMEOUT
        try:
            os.kill(self.pid, 0)
            return True
        except OSError:
            return False

    def close(self) -> None:
        if self.handle is not None and self.kernel is not None:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


DEMO_STATES = ("idle", "working", "attention", "success", "error", "stopped", "offline", "incompatible")
DEMO_MESSAGES = (
    "演示：等你派发新任务", "演示：正在处理 2 个任务", "演示：有一个任务需要你处理",
    "演示：这一轮完成啦！", "演示：有任务失败", "演示：任务已停止",
    "演示：T3 暂时断开", "演示：版本尚不支持",
)


def demo_document(step: int, observed_at: datetime | None = None) -> dict:
    observed_at = observed_at or utc_now()
    index = step % len(DEMO_STATES)
    state = DEMO_STATES[index]
    return {
        "schema_version": 1, "observed_at": timestamp(observed_at), "mode": "demo",
        "state": state, "message": DEMO_MESSAGES[index],
        "source": {"kind": "demo", "version": "", "health":
                   "disconnected" if state == "offline" else "incompatible" if state == "incompatible" else "connected"},
        "counts": {"working": 2 if state == "working" else 0,
                   "waiting_user": 1 if state == "attention" else 0,
                   "pending": 1 if state in ("working", "attention") else 0,
                   "failed": 1 if state == "error" else 0},
        "event": {"id": f"demo-{step}", "kind": state} if state in ("success", "error", "stopped") else None,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Read-only T3 status collector for Rebecca.")
    result.add_argument("--t3-home", default=os.environ.get("T3CODE_HOME"))
    result.add_argument("--output", required=True)
    result.add_argument("--poll", type=float, default=2.0)
    result.add_argument("--project-id", action="append", default=[])
    result.add_argument("--once", action="store_true")
    result.add_argument("--demo", action="store_true")
    result.add_argument("--parent-pid", type=int)
    return result


def main(argv: list[str] | None = None) -> int:
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    if not math.isfinite(args.poll) or not 0.2 <= args.poll <= 60:
        argument_parser.error("--poll must be between 0.2 and 60 seconds")
    if not args.demo and not args.t3_home:
        argument_parser.error("--t3-home is required in live mode")
    diagnostics = None
    parents: list[ParentGuard] = []
    try:
        destination = output_path(args.output)
        diagnostics = Diagnostics(destination)
        adapter = None if args.demo else SQLiteAdapter(args.t3_home, tuple(args.project_id))
        parents.append(ParentGuard(args.parent_pid))
        if args.parent_pid is not None:
            # Windows venv python.exe can be a launcher with a separate real
            # Python child. Observe both the UI and that immediate launcher so
            # killing the owned launcher cannot leave a competing writer.
            launcher_pid = os.getppid()
            if launcher_pid > 0 and launcher_pid != args.parent_pid:
                parents.append(ParentGuard(launcher_pid))
    except (OSError, ValueError) as exc:
        for parent in parents:
            parent.close()
        if diagnostics is not None:
            diagnostics.write("configuration_error", exc)
        report_error("Rebecca collector: invalid output, parent or source configuration.")
        return 2

    stop = threading.Event()
    old_signals: dict[int, object] = {}
    if threading.current_thread() is threading.main_thread():
        for signal_number in (signal.SIGINT, signal.SIGTERM):
            old_signals[signal_number] = signal.signal(signal_number, lambda *_: stop.set())
    reducer = Reducer()
    started = time.monotonic()
    failures = 0
    write_failures = 0
    source_error = False
    diagnostics.write("started")
    try:
        while not stop.is_set() and all(parent.alive() for parent in parents):
            iteration_start = time.monotonic()
            if args.demo:
                document = demo_document(int((iteration_start - started) // 5))
            else:
                try:
                    sample = adapter.read()  # type: ignore[union-attr]
                    document = reducer.reduce(sample)
                    source_error = False
                except Exception as exc:
                    # Keep UI honest, but never put a private SQL row, local
                    # credential or provider exception into JSON or logs.
                    if not source_error:
                        diagnostics.write("source_error", exc)
                    source_error = True
                    document = reducer.reduce(Failure("offline", "collector_error", "状态采集暂时不可用", "error"))
            document["poll_seconds"] = args.poll
            try:
                atomic_write(destination, document)
            except OSError as exc:
                if not write_failures:
                    diagnostics.write("snapshot_write_failed", exc)
                write_failures = min(write_failures + 1, 3)
                if args.once:
                    report_error("Rebecca collector: cannot write the status snapshot.")
                    return 2
                # A temporary lock or unavailable disk must not end monitoring.
                # Keep the previous file untouched; the UI detects its age.
            except (ValueError, TypeError) as exc:
                diagnostics.write("invalid_snapshot", exc)
                report_error("Rebecca collector: invalid status snapshot.")
                return 2
            else:
                if write_failures:
                    diagnostics.write("snapshot_write_recovered")
                write_failures = 0
            if args.once:
                return 0
            failures = min(failures + 1, 3) if document["source"]["health"] != "connected" and not args.demo else 0
            # Bound backoff below the UI's minimum stale threshold. Healthy
            # polls are interval-aligned, rather than query duration + interval.
            retry_level = max(failures, write_failures)
            interval = min(max(args.poll, 8.0), args.poll * (2 ** retry_level)) if retry_level else args.poll
            remaining = max(0.0, interval - (time.monotonic() - iteration_start))
            wait_until = time.monotonic() + remaining
            while not stop.is_set() and all(parent.alive() for parent in parents) and time.monotonic() < wait_until:
                stop.wait(min(0.2, max(0.0, wait_until - time.monotonic())))
        diagnostics.write("stop_requested" if stop.is_set() else "parent_unavailable")
        return 0
    except Exception as exc:
        diagnostics.write("unexpected_exit", exc)
        report_error("Rebecca collector: unexpected failure; see the diagnostic log.")
        return 2
    finally:
        diagnostics.write("stopped")
        for parent in parents:
            parent.close()
        for signal_number, previous in old_signals.items():
            signal.signal(signal_number, previous)


if __name__ == "__main__":
    raise SystemExit(main())
