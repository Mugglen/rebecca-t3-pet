"""Pure status reduction. No filesystem, database or network access."""

from __future__ import annotations

from dataclasses import dataclass
from collections import deque
from datetime import datetime, timedelta, timezone
import hashlib
from typing import Literal


ACTIVE = frozenset({"preparing", "queued", "starting", "running", "waiting"})
TERMINAL = frozenset({"completed", "failed", "interrupted", "cancelled", "rolled_back"})
KNOWN_STATUSES = ACTIVE | TERMINAL | {"idle"}
USER_REQUEST_KINDS = frozenset({
    "user_input", "command", "file-read", "file-change", "mcp-elicitation", "permission"
})


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_timestamp(value: str) -> datetime:
    if not isinstance(value, str) or len(value) > 64:
        raise ValueError("invalid timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamp must include a time zone")
    return result.astimezone(timezone.utc)


@dataclass(frozen=True)
class Run:
    thread_id: str
    run_id: str
    status: str
    requested_at: datetime
    completed_at: datetime | None = None


@dataclass(frozen=True)
class Request:
    request_id: str
    thread_id: str
    kind: str
    blocking: bool | None

    @property
    def needs_user(self) -> bool:
        return self.kind in USER_REQUEST_KINDS


@dataclass(frozen=True)
class Thread:
    """One top-level task, including metadata of its eligible descendants."""

    thread_id: str
    project_id: str
    runs: tuple[Run, ...] = ()
    requests: tuple[Request, ...] = ()


@dataclass(frozen=True)
class Snapshot:
    observed_at: datetime
    service_id: str
    version: str
    threads: tuple[Thread, ...]
    scope: tuple[str, ...] = ()
    limitations: tuple[str, ...] = ()


@dataclass(frozen=True)
class Failure:
    state: Literal["offline", "incompatible"]
    reason: str
    message: str
    health: Literal["disconnected", "error", "incompatible"] = "disconnected"
    version: str = ""


@dataclass(frozen=True)
class Event:
    id: str
    kind: str
    occurred_at: datetime
    expires_at: datetime


class Reducer:
    """Tracks only this connection's run baseline; restarting never replays history."""

    def __init__(self, event_ttl: float = 5.0) -> None:
        if not 0 < event_ttl <= 60:
            raise ValueError("event TTL must be between 0 and 60 seconds")
        self.event_ttl = event_ttl
        self._identity: tuple[str, tuple[str, ...]] | None = None
        self._baseline_at: datetime | None = None
        self._previous: dict[tuple[str, str], str] = {}
        self._seen: set[tuple[str, str, str]] = set()
        self._seen_order: deque[tuple[str, str, str]] = deque()
        self._events: list[Event] = []

    def _reset(self) -> None:
        self._identity = None
        self._baseline_at = None
        self._previous.clear()
        self._seen.clear()
        self._seen_order.clear()
        self._events.clear()

    def reduce(self, value: Snapshot | Failure, *, now: datetime | None = None) -> dict:
        observed = now or (value.observed_at if isinstance(value, Snapshot) else utc_now())
        if isinstance(value, Failure):
            self._reset()
            return self._document(observed, value.state, value.message, value.version,
                                  value.health, {}, None, reason=value.reason)

        runs = {(r.thread_id, r.run_id): r for t in value.threads for r in t.runs}
        if any(r.status not in KNOWN_STATUSES for r in runs.values()):
            return self.reduce(Failure("incompatible", "unknown_run_status",
                                       "T3 状态格式尚不支持", "incompatible", value.version), now=observed)

        identity = (value.service_id, tuple(sorted(value.scope)))
        initial = self._identity != identity
        if initial:
            self._reset()
            self._identity = identity
            self._baseline_at = observed

        self._events = [e for e in self._events if e.expires_at > observed]
        new_events: list[Event] = []
        for key, run in runs.items():
            if run.status not in TERMINAL:
                continue
            event_key = (*key, run.status)
            if initial:
                self._remember(event_key)
                continue
            previous = self._previous.get(key)
            # A known active run may predate this connection; a never-observed run
            # must have been requested after the baseline to count as a fast finish.
            eligible = (previous is not None and previous != run.status) or (
                previous is None and self._baseline_at is not None
                and run.requested_at > self._baseline_at
            )
            if event_key not in self._seen and eligible:
                kind = "success" if run.status == "completed" else "error" if run.status == "failed" else "stopped"
                digest = hashlib.sha256("\0".join(event_key).encode()).hexdigest()[:24]
                new_events.append(Event(digest, kind, observed,
                                        observed + timedelta(seconds=self.event_ttl)))
            self._remember(event_key)
        self._events.extend(new_events)
        self._previous = {key: run.status for key, run in runs.items()}

        counts = {"working": 0, "waiting_user": 0, "pending": 0, "failed": 0}
        unknown_requests = 0
        for thread in value.threads:
            active_threads = {r.thread_id for r in thread.runs if r.status in ACTIVE}
            blocked_threads = {r.thread_id for r in thread.requests if r.needs_user and r.blocking is True}
            # A blocked child and a working parent may coexist: both dimensions
            # remain observable, while each top-level task counts only once.
            counts["working"] += bool(active_threads - blocked_threads)
            counts["waiting_user"] += bool(blocked_threads)
            counts["pending"] += sum(r.needs_user for r in thread.requests)
            counts["failed"] += any(r.status == "failed" for r in thread.runs)
            unknown_requests += sum(r.blocking is None or not r.needs_user for r in thread.requests)

        # Preserve simultaneous events during their TTL, with failures taking
        # precedence. The visible event ID is stable across identical snapshots.
        event = max(self._events, key=lambda e: (e.kind == "error", e.occurred_at, e.id), default=None)
        if counts["waiting_user"]:
            state, message = "attention", f"有 {counts['waiting_user']} 个任务需要你处理"
        elif event is not None and event.kind == "error":
            state, message = "error", "有任务失败，回 T3 看一下"
        elif counts["working"]:
            state, message = "working", f"正在处理 {counts['working']} 个任务"
        elif event is not None:
            state = event.kind
            message = "这一轮完成啦！" if state == "success" else "任务已停止"
        else:
            state, message = "idle", "等你派发新任务"
        if counts["pending"] and not counts["waiting_user"]:
            message += f" · {counts['pending']} 条待回复"
        elif unknown_requests:
            message += " · 有待处理请求"

        event_data = None if event is None else {
            "id": event.id, "kind": event.kind,
            "occurred_at": timestamp(event.occurred_at), "expires_at": timestamp(event.expires_at),
        }
        result = self._document(observed, state, message, value.version,
                                "connected", counts, event_data)
        result["source"]["scope"] = list(value.scope)
        result["source"]["limitations"] = list(value.limitations)
        result["source"]["task_count"] = len(value.threads)
        return result

    def _remember(self, key: tuple[str, str, str]) -> None:
        if key in self._seen:
            return
        self._seen.add(key)
        self._seen_order.append(key)
        if len(self._seen_order) > 20_000:
            self._seen.discard(self._seen_order.popleft())

    @staticmethod
    def _document(observed: datetime, state: str, message: str, version: str,
                  health: str, counts: dict, event: dict | None, **extra: str) -> dict:
        source = {"kind": "sqlite-readonly", "version": version, "health": health}
        source.update(extra)
        return {
            "schema_version": 1, "observed_at": timestamp(observed), "mode": "live",
            "state": state, "message": message, "source": source,
            "counts": {key: int(counts.get(key, 0)) for key in ("working", "waiting_user", "pending", "failed")},
            "event": event,
        }
