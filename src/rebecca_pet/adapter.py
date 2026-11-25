"""Version-gated, metadata-only reader for T3's private SQLite projection."""

from __future__ import annotations

from collections import defaultdict
import http.client
import ipaddress
import json
from pathlib import Path
import socket
import sqlite3
import threading
import time
from typing import Callable

from .state import ACTIVE, Failure, KNOWN_STATUSES, Request, Run, Snapshot, Thread, parse_timestamp, timestamp, utc_now


SUPPORTED_VERSIONS = frozenset({"0.1.11"})
MAX_JSON_BYTES = 64 * 1024
MAX_ROWS = 20_000
TABLE_PREFIX = "orchestration_v2_projection_"
REQUIRED_COLUMNS = {
    "threads": {"thread_id", "project_id", "archived_at", "deleted_at", "payload_json"},
    "runs": {"run_id", "thread_id", "ordinal", "status", "requested_at", "completed_at"},
    "runtime_requests": {"runtime_request_id", "thread_id", "node_id", "kind", "status", "created_at", "payload_json"},
}
LIMITATIONS = (
    "secret/link cards are not included; check T3 for these requests",
    "private raw-run projection; background wakes and usage-limit recovery are not reconstructed",
)


class ReadError(Exception):
    """Carries only a safe error classification, never raw provider data."""

    def __init__(self, failure: Failure):
        super().__init__(failure.reason)
        self.failure = failure


def incompatible(reason: str, version: str = "") -> ReadError:
    return ReadError(Failure("incompatible", reason, "T3 版本或状态格式尚不支持", "incompatible", version))


def unavailable(reason: str, *, health: str = "disconnected", version: str = "") -> ReadError:
    return ReadError(Failure("offline", reason, "暂时无法读取 T3 状态", health, version))


def _read_json(path: Path) -> dict:
    with path.open("rb") as stream:
        data = stream.read(MAX_JSON_BYTES + 1)
    if len(data) > MAX_JSON_BYTES:
        raise incompatible("runtime_document_too_large")
    result = json.loads(data.decode("utf-8-sig"))
    if not isinstance(result, dict):
        raise incompatible("runtime_document_shape")
    return result


def _safe_id(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 256:
        raise incompatible("invalid_" + field)
    return value


def _loopback_host(value: object) -> str:
    if value == "localhost":
        return "127.0.0.1"
    if not isinstance(value, str):
        raise unavailable("non_loopback_host")
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise unavailable("non_loopback_host") from exc
    if not address.is_loopback:
        raise unavailable("non_loopback_host")
    return str(address)


def read_descriptor(host: str, port: int, timeout: float) -> dict:
    """Direct loopback HTTP: no proxies, credentials or redirects; bounded body/time.

    A deadline timer shuts down the socket, so trickled headers/body cannot reset
    the timeout indefinitely. HTTPConnection itself also has a socket timeout.
    """
    host = _loopback_host(host)
    if type(port) is not int or not 1 <= port <= 65535:
        raise unavailable("invalid_port")
    if not 0 < timeout <= 10:
        raise ValueError("timeout must be in (0, 10]")
    deadline = time.monotonic() + timeout
    connection = http.client.HTTPConnection(host, port, timeout=timeout)
    timer: threading.Timer | None = None
    try:
        connection.connect()
        current_socket = connection.sock

        def expire() -> None:
            if current_socket is not None:
                try:
                    current_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                current_socket.close()

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("descriptor deadline")
        timer = threading.Timer(remaining, expire)
        timer.daemon = True
        timer.start()
        connection.request("GET", "/.well-known/t3/environment", headers={
            "Accept": "application/json", "Connection": "close",
        })
        response = connection.getresponse()
        if response.status != 200:
            raise unavailable("descriptor_http_status")
        if response.getheader("Content-Type", "").split(";", 1)[0].lower().strip() != "application/json":
            raise unavailable("descriptor_not_json")
        content_length = response.getheader("Content-Length")
        if content_length is not None:
            try:
                if int(content_length) > MAX_JSON_BYTES or int(content_length) < 0:
                    raise unavailable("descriptor_too_large")
            except ValueError as exc:
                raise unavailable("descriptor_length") from exc
        body = response.read(MAX_JSON_BYTES + 1)
        if time.monotonic() > deadline:
            raise unavailable("descriptor_timeout")
        if len(body) > MAX_JSON_BYTES:
            raise unavailable("descriptor_too_large")
        descriptor = json.loads(body.decode("utf-8"))
        if not isinstance(descriptor, dict):
            raise unavailable("descriptor_shape")
        return descriptor
    except ReadError:
        raise
    except (OSError, ValueError, http.client.HTTPException) as exc:
        raise unavailable("descriptor_unavailable") from exc
    finally:
        if timer is not None:
            timer.cancel()
        connection.close()


class SQLiteAdapter:
    def __init__(self, t3_home: Path | str, project_ids: tuple[str, ...] = (),
                 timeout: float = 2.0,
                 descriptor_reader: Callable[[str, int, float], dict] = read_descriptor) -> None:
        self.home = Path(t3_home)
        self.project_ids = tuple(sorted(set(project_ids)))
        if any(not isinstance(item, str) or not item or len(item) > 256 for item in self.project_ids):
            raise ValueError("invalid project ID")
        if not 0.1 <= timeout <= 10:
            raise ValueError("timeout must be between 0.1 and 10 seconds")
        self.timeout = timeout
        self.descriptor_reader = descriptor_reader
        self._service_id: str | None = None
        self._active_run_ids: set[str] = set()
        self._last_read_at: str | None = None

    def read(self) -> Snapshot | Failure:
        try:
            return self._read()
        except ReadError as exc:
            failure = exc.failure
        except (FileNotFoundError, PermissionError, OSError):
            failure = Failure("offline", "runtime_unavailable", "暂时无法读取 T3 状态")
        except (ValueError, TypeError, KeyError):
            failure = Failure("incompatible", "invalid_metadata", "T3 状态格式尚不支持", "incompatible")
        except sqlite3.Error as exc:
            if any(marker in str(exc).lower() for marker in ("malformed json", "no such column", "no such table", "not a database", "database disk image is malformed")):
                failure = Failure("incompatible", "invalid_database_structure", "T3 状态格式尚不支持", "incompatible")
            else:
                failure = Failure("offline", "database_unavailable", "T3 状态读取失败", "error")
        # Reconnection starts a fresh baseline in both adapter and reducer.
        # Do not accumulate an unbounded terminal backlog during an outage.
        self._service_id = None
        self._active_run_ids.clear()
        self._last_read_at = None
        return failure

    def _read(self) -> Snapshot:
        deadline = time.monotonic() + self.timeout
        read_started_at = utc_now()
        userdata = self.home / "userdata"
        runtime = _read_json(userdata / "server-runtime.json")
        version = _safe_id(runtime.get("serverVersion"), "version")
        if version not in SUPPORTED_VERSIONS:
            raise incompatible("unsupported_version", version)
        host = _loopback_host(runtime.get("host"))
        port = runtime.get("port")
        if type(port) is not int or not 1 <= port <= 65535:
            raise unavailable("invalid_port", version=version)
        started_at = _safe_id(runtime.get("startedAt"), "service_start")
        parse_timestamp(started_at)
        if type(runtime.get("pid")) is not int or runtime["pid"] <= 0:
            raise unavailable("invalid_service_pid", version=version)
        with (userdata / "environment-id").open("r", encoding="utf-8-sig") as stream:
            environment_id = _safe_id(stream.read(257).strip(), "environment_id")
        descriptor = self.descriptor_reader(host, port, max(0.001, deadline - time.monotonic()))
        if descriptor.get("environmentId") != environment_id:
            raise unavailable("environment_identity_mismatch", version=version)
        if descriptor.get("serverVersion") != version:
            raise incompatible("environment_version_mismatch", version)
        # These are numeric schema/protocol revision markers in 0.1.11, not
        # generic truthy readiness flags. A changed revision needs revalidation.
        if (type(descriptor.get("orchestrationProtocolVersion")) is not int
                or descriptor["orchestrationProtocolVersion"] != 2):
            raise incompatible("unsupported_orchestration_protocol", version)
        if (type(descriptor.get("databaseMigration")) is not int
                or descriptor["databaseMigration"] != 102):
            raise incompatible("unsupported_database_migration", version)
        if time.monotonic() >= deadline:
            raise unavailable("snapshot_timeout", version=version)
        service_id = f"{environment_id}:{runtime['pid']}:{started_at}"
        same_service = service_id == self._service_id
        tracked_ids = sorted(self._active_run_ids) if same_service else []
        since = self._last_read_at if same_service else None

        db_path = (userdata / "statev2.sqlite").resolve()
        # mode=ro prevents creation. Do not use immutable=1: live WAL must be read.
        connection = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True,
                                     timeout=min(0.15, max(0.001, deadline - time.monotonic())))
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA query_only=ON")
            connection.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
            connection.execute("BEGIN")
            self._validate_schema(connection, version)
            threads = self._query(connection, """
                SELECT t.thread_id, t.project_id,
                       json_extract(t.payload_json, '$.lineage.parentThreadId') AS parent_id,
                       json_extract(t.payload_json, '$.lineage.relationshipToParent') AS relationship,
                       json_extract(t.payload_json, '$.settledOverride') AS settled_override,
                       r.run_id, r.ordinal, r.status, r.requested_at, r.completed_at
                FROM orchestration_v2_projection_threads AS t
                LEFT JOIN orchestration_v2_projection_runs AS r ON r.run_id = (
                    SELECT r2.run_id FROM orchestration_v2_projection_runs AS r2
                    WHERE r2.thread_id = t.thread_id ORDER BY r2.ordinal DESC LIMIT 1)
                WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
            """)
            active = self._query(connection, """
                SELECT r.run_id, r.thread_id, r.status, r.requested_at, r.completed_at
                FROM orchestration_v2_projection_runs AS r
                JOIN orchestration_v2_projection_threads AS t ON t.thread_id = r.thread_id
                WHERE r.status IN ('preparing', 'queued', 'starting', 'running', 'waiting')
                  AND t.archived_at IS NULL AND t.deleted_at IS NULL
            """)
            # Older runs must remain observable when they stop being ACTIVE.
            # Query remembered IDs in bounded batches, and terminal changes
            # since the previous successful read to catch short runs that both
            # start and finish between polls (even if they are no longer latest).
            terminal = []
            for offset in range(0, len(tracked_ids), 400):
                batch = tracked_ids[offset:offset + 400]
                placeholders = ",".join("?" for _ in batch)
                terminal.extend(self._query(connection, f"""
                    SELECT r.run_id, r.thread_id, r.status, r.requested_at, r.completed_at
                    FROM orchestration_v2_projection_runs AS r
                    JOIN orchestration_v2_projection_threads AS t ON t.thread_id = r.thread_id
                    WHERE r.run_id IN ({placeholders})
                      AND t.archived_at IS NULL AND t.deleted_at IS NULL
                """, tuple(batch)))
            if since is not None:
                terminal.extend(self._query(connection, """
                    SELECT r.run_id, r.thread_id, r.status, r.requested_at, r.completed_at
                    FROM orchestration_v2_projection_runs AS r
                    JOIN orchestration_v2_projection_threads AS t ON t.thread_id = r.thread_id
                    WHERE r.status IN ('completed', 'failed', 'interrupted', 'cancelled', 'rolled_back')
                      AND (julianday(r.completed_at) >= julianday(?)
                           OR julianday(r.requested_at) >= julianday(?))
                      AND t.archived_at IS NULL AND t.deleted_at IS NULL
                """, (since, since)))
            requests = self._query(connection, """
                SELECT q.runtime_request_id, q.thread_id, q.kind,
                       json_extract(q.payload_json, '$.responseCapability.type') AS response_type
                FROM orchestration_v2_projection_runtime_requests AS q
                JOIN orchestration_v2_projection_threads AS t ON t.thread_id = q.thread_id
                WHERE q.status = 'pending' AND t.archived_at IS NULL AND t.deleted_at IS NULL
            """)
            if time.monotonic() >= deadline:
                raise unavailable("snapshot_timeout", version=version)
        finally:
            connection.rollback()
            connection.close()

        # Reject a snapshot straddling a service restart; the next poll will build
        # a fresh reducer baseline for the new service identity.
        after = _read_json(userdata / "server-runtime.json")
        if any(after.get(key) != runtime.get(key) for key in ("pid", "startedAt", "host", "port", "serverVersion")):
            raise unavailable("service_restarted", version=version)
        groups = self._group(threads, [*active, *terminal], requests, version)
        self._service_id = service_id
        self._active_run_ids = {r.run_id for t in groups for r in t.runs if r.status in ACTIVE}
        # Use the read's start, not its end, so a DB commit during the read
        # cannot fall through the gap between consistent snapshots.
        self._last_read_at = timestamp(read_started_at)
        return Snapshot(utc_now(), service_id,
                        version, groups, self.project_ids, LIMITATIONS)

    @staticmethod
    def _validate_schema(connection: sqlite3.Connection, version: str) -> None:
        for suffix, expected in REQUIRED_COLUMNS.items():
            columns = {row[1] for row in connection.execute(f"PRAGMA table_info({TABLE_PREFIX}{suffix})")}
            if not expected <= columns:
                raise incompatible("schema_mismatch_" + suffix, version)
        try:
            if connection.execute("SELECT json_extract('{\"value\":1}', '$.value')").fetchone()[0] != 1:
                raise incompatible("sqlite_json_unavailable", version)
        except sqlite3.Error as exc:
            raise incompatible("sqlite_json_unavailable", version) from exc

    @staticmethod
    def _query(connection: sqlite3.Connection, query: str, parameters: tuple = ()) -> list[sqlite3.Row]:
        rows = connection.execute(query, parameters).fetchmany(MAX_ROWS + 1)
        if len(rows) > MAX_ROWS:
            raise incompatible("snapshot_row_limit")
        return rows

    def _group(self, rows: list[sqlite3.Row], active: list[sqlite3.Row],
               requests: list[sqlite3.Row], version: str) -> tuple[Thread, ...]:
        by_id = {str(row["thread_id"]): row for row in rows}
        if any(row["relationship"] not in (None, "fork", "subagent")
               or row["settled_override"] not in (None, "active", "settled") for row in rows):
            raise incompatible("unknown_thread_metadata", version)
        roots: dict[str, str | None] = {}

        def root_of(thread_id: str) -> str | None:
            if thread_id in roots:
                return roots[thread_id]
            chain: set[str] = set()
            current = thread_id
            while current in by_id:
                if current in chain:
                    raise incompatible("thread_lineage_cycle", version)
                chain.add(current)
                row = by_id[current]
                if row["settled_override"] == "settled":
                    result = None
                    break
                if row["relationship"] != "subagent":
                    result = current
                    break
                parent = row["parent_id"]
                if not isinstance(parent, str) or not parent:
                    result = None
                    break
                current = parent
            else:
                result = None  # orphan children do not become independent tasks
            for entry in chain:
                roots[entry] = result
            return result

        for thread_id in by_id:
            root_of(thread_id)
        selected = {
            root for root in roots.values() if root is not None
            and (not self.project_ids or by_id[root]["project_id"] in self.project_ids)
        }
        run_groups: dict[str, dict[tuple[str, str], Run]] = defaultdict(dict)
        request_groups: dict[str, list[Request]] = defaultdict(list)
        for row in [*rows, *active]:
            root = roots.get(row["thread_id"])
            if root not in selected or row["run_id"] is None:
                continue
            status = row["status"]
            if status not in KNOWN_STATUSES:
                raise incompatible("unknown_run_status", version)
            run = Run(_safe_id(row["thread_id"], "thread_id"), _safe_id(row["run_id"], "run_id"), status,
                      parse_timestamp(row["requested_at"]),
                      parse_timestamp(row["completed_at"]) if row["completed_at"] else None)
            run_groups[root][(run.thread_id, run.run_id)] = run
        for row in requests:
            root = roots.get(row["thread_id"])
            if root not in selected:
                continue
            response_type = row["response_type"]
            blocking = False if response_type == "message" else True if response_type == "live" else None
            request_groups[root].append(Request(
                _safe_id(row["runtime_request_id"], "request_id"),
                _safe_id(row["thread_id"], "thread_id"), _safe_id(row["kind"], "request_kind"), blocking))
        return tuple(Thread(_safe_id(root, "thread_id"), _safe_id(by_id[root]["project_id"], "project_id"),
                            tuple(run_groups[root].values()), tuple(request_groups[root]))
                     for root in sorted(selected))
