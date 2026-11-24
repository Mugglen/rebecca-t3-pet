from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest

from rebecca_pet.adapter import MAX_JSON_BYTES, ReadError, SQLiteAdapter, read_descriptor
from rebecca_pet.state import Failure, Snapshot


ROOT = Path(__file__).resolve().parents[1]
TEST_TEMP = ROOT / "tmp" / "tests"
DESCRIPTOR = {"environmentId": "env-test", "serverVersion": "0.1.11",
              "orchestrationProtocolVersion": 2, "databaseMigration": 102}


@contextmanager
def writable_db(path):
    connection = sqlite3.connect(path)
    try:
        yield connection
        connection.commit()
    finally:
        connection.close()


@contextmanager
def http_response(body=b"{}", status=200, content_type="application/json", delay=0, headers=None):
    paths = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            paths.append(self.path)
            if delay:
                time.sleep(delay)
            try:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
    thread.start()
    try:
        yield server.server_address[1], paths
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


class AdapterFixture(unittest.TestCase):
    def setUp(self):
        TEST_TEMP.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="adapter-", dir=TEST_TEMP)
        self.home = Path(self.temporary.name)
        self.userdata = self.home / "userdata"
        self.userdata.mkdir()
        self.runtime = {"serverVersion": "0.1.11", "host": "127.0.0.1", "port": 3773,
                        "pid": 123, "startedAt": "2026-11-25T00:00:00Z"}
        self.write_runtime()
        (self.userdata / "environment-id").write_text("env-test", encoding="utf-8")
        self.db = self.userdata / "statev2.sqlite"
        with writable_db(self.db) as connection:
            connection.executescript("""
                CREATE TABLE orchestration_v2_projection_threads (
                    thread_id TEXT PRIMARY KEY, project_id TEXT, archived_at TEXT,
                    deleted_at TEXT, payload_json TEXT);
                CREATE TABLE orchestration_v2_projection_runs (
                    run_id TEXT PRIMARY KEY, thread_id TEXT, ordinal INTEGER, status TEXT,
                    requested_at TEXT, completed_at TEXT);
                CREATE INDEX run_thread_ordinal ON orchestration_v2_projection_runs(thread_id, ordinal DESC);
                CREATE TABLE orchestration_v2_projection_runtime_requests (
                    runtime_request_id TEXT PRIMARY KEY, thread_id TEXT, node_id TEXT,
                    kind TEXT, status TEXT, created_at TEXT, payload_json TEXT);
            """)

    def tearDown(self):
        self.temporary.cleanup()

    def write_runtime(self):
        (self.userdata / "server-runtime.json").write_text(json.dumps(self.runtime), encoding="utf-8")

    def thread(self, identifier="t1", project="p1", parent=None, relationship=None, settled=None, archived=None):
        payload = {"lineage": {"parentThreadId": parent, "relationshipToParent": relationship},
                   "settledOverride": settled}
        with writable_db(self.db) as connection:
            connection.execute("INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?)",
                               (identifier, project, archived, None, json.dumps(payload)))

    def add_run(self, identifier="r1", thread="t1", status="running", ordinal=1):
        with writable_db(self.db) as connection:
            connection.execute("INSERT INTO orchestration_v2_projection_runs VALUES (?,?,?,?,?,?)",
                               (identifier, thread, ordinal, status, "2026-11-25T00:00:00Z", None))

    def request(self, identifier="q1", thread="t1", kind="user_input", response="message"):
        with writable_db(self.db) as connection:
            connection.execute("INSERT INTO orchestration_v2_projection_runtime_requests VALUES (?,?,?,?,?,?,?)",
                               (identifier, thread, "node", kind, "pending", "2026-11-25T00:00:00Z",
                                json.dumps({"responseCapability": {"type": response}})))

    def adapter(self, projects=(), descriptor=None):
        return SQLiteAdapter(self.home, projects, descriptor_reader=lambda *_: dict(descriptor or DESCRIPTOR))

    def test_read_only_snapshot_does_not_change_database(self):
        self.thread()
        self.add_run()
        before = hashlib.sha256(self.db.read_bytes()).hexdigest()
        result = self.adapter().read()
        self.assertIsInstance(result, Snapshot)
        self.assertEqual(result.threads[0].runs[0].status, "running")
        self.assertEqual(before, hashlib.sha256(self.db.read_bytes()).hexdigest())
        self.assertTrue(result.limitations)

    def test_read_connection_rejects_mutation(self):
        self.thread()
        test = self
        class ProbeAdapter(SQLiteAdapter):
            @staticmethod
            def _validate_schema(connection, version):
                test.assertEqual(connection.execute("PRAGMA query_only").fetchone()[0], 1)
                with test.assertRaises(sqlite3.OperationalError):
                    connection.execute("DELETE FROM orchestration_v2_projection_threads")
                SQLiteAdapter._validate_schema(connection, version)
        probe = ProbeAdapter(self.home, descriptor_reader=lambda *_: dict(DESCRIPTOR))
        self.assertEqual(len(probe.read().threads), 1)

    def test_old_active_run_survives_newer_completed_run(self):
        self.thread()
        self.add_run("old", ordinal=1)
        self.add_run("new", status="completed", ordinal=2)
        result = self.adapter().read()
        self.assertEqual({r.run_id for r in result.threads[0].runs}, {"old", "new"})

    def test_requests_map_known_and_unknown_blocking(self):
        self.thread()
        for name, capability in (("async", "message"), ("sync", "live"), ("unknown", "future")):
            self.request(name, response=capability)
        requests = {q.request_id: q.blocking for q in self.adapter().read().threads[0].requests}
        self.assertEqual(requests, {"async": False, "sync": True, "unknown": None})

    def test_children_aggregate_and_forks_remain_independent(self):
        self.thread()
        self.thread("child", "p2", "t1", "subagent")
        self.thread("fork", "p2", "t1", "fork")
        self.add_run("childrun", "child")
        self.request(thread="child")
        filtered = self.adapter(("p1",)).read()
        self.assertEqual(len(filtered.threads), 1)
        self.assertEqual(filtered.threads[0].runs[0].thread_id, "child")
        self.assertEqual(len(filtered.threads[0].requests), 1)
        self.assertEqual(len(self.adapter().read().threads), 2)

    def test_settled_archived_orphan_and_other_scope_excluded(self):
        self.thread("settled", settled="settled")
        self.thread("child", parent="settled", relationship="subagent")
        self.thread("archived", archived="2026-11-25T00:00:00Z")
        self.thread("orphan", parent="missing", relationship="subagent")
        self.thread("other", project="p2")
        self.assertEqual(self.adapter(("p1",)).read().threads, ())

    def test_scope_string_is_not_sql(self):
        self.thread()
        self.assertEqual(self.adapter(("p1' OR 1=1 --",)).read().threads, ())

    def test_lineage_cycle_is_incompatible(self):
        self.thread("a", parent="b", relationship="subagent")
        self.thread("b", parent="a", relationship="subagent")
        self.assertEqual(self.adapter().read().state, "incompatible")

    def test_missing_schema_is_incompatible(self):
        with writable_db(self.db) as connection:
            connection.execute("DROP TABLE orchestration_v2_projection_runtime_requests")
        self.assertEqual(self.adapter().read().state, "incompatible")

    def test_unknown_run_status_is_incompatible(self):
        self.thread()
        self.add_run(status="unrecognized")
        self.assertEqual(self.adapter().read().state, "incompatible")

    def test_invalid_json_metadata_is_incompatible(self):
        self.thread()
        with writable_db(self.db) as connection:
            connection.execute("UPDATE orchestration_v2_projection_threads SET payload_json='broken'")
        self.assertEqual(self.adapter().read().state, "incompatible")

    def test_missing_database_does_not_create_new_one(self):
        self.db.unlink()
        self.assertIsInstance(self.adapter().read(), Failure)
        self.assertFalse(self.db.exists())

    def test_unknown_version_fails_before_http(self):
        self.runtime["serverVersion"] = "99.1.0"
        self.write_runtime()
        adapter = SQLiteAdapter(self.home, descriptor_reader=lambda *_: self.fail("network called"))
        self.assertEqual(adapter.read().state, "incompatible")

    def test_remote_host_rejected_before_http(self):
        self.runtime["host"] = "192.0.2.1"
        self.write_runtime()
        adapter = SQLiteAdapter(self.home, descriptor_reader=lambda *_: self.fail("network called"))
        self.assertEqual(adapter.read().state, "offline")

    def test_identity_mismatch_is_offline(self):
        descriptor = dict(DESCRIPTOR, environmentId="another-environment")
        self.assertEqual(self.adapter(descriptor=descriptor).read().state, "offline")

    def test_migration_and_protocol_must_be_validated(self):
        for key in ("databaseMigration", "orchestrationProtocolVersion"):
            with self.subTest(key=key):
                self.assertEqual(self.adapter(descriptor=dict(DESCRIPTOR, **{key: 999})).read().state, "incompatible")

    def test_service_restart_during_read_is_unavailable(self):
        def health(*_):
            self.runtime["pid"] += 1
            self.write_runtime()
            return dict(DESCRIPTOR)
        result = SQLiteAdapter(self.home, descriptor_reader=health).read()
        self.assertEqual(result.state, "offline")
        self.assertEqual(result.reason, "service_restarted")


class DescriptorTests(unittest.TestCase):
    def test_json_descriptor_at_exact_endpoint(self):
        with http_response(json.dumps(DESCRIPTOR).encode()) as (port, paths):
            self.assertEqual(read_descriptor("127.0.0.1", port, 1), DESCRIPTOR)
            self.assertEqual(paths, ["/.well-known/t3/environment"])

    def test_spa_200_not_healthy(self):
        with http_response(b"<html>T3 Code</html>", content_type="text/html") as (port, _):
            with self.assertRaises(ReadError):
                read_descriptor("127.0.0.1", port, 1)

    def test_no_redirect_following(self):
        with http_response(status=302, headers={"Location": "http://192.0.2.1/"}) as (port, paths):
            with self.assertRaises(ReadError):
                read_descriptor("127.0.0.1", port, 1)
            self.assertEqual(len(paths), 1)

    def test_body_size_bound(self):
        with http_response(b"x" * (MAX_JSON_BYTES + 1)) as (port, _):
            with self.assertRaises(ReadError):
                read_descriptor("127.0.0.1", port, 1)

    def test_total_deadline(self):
        with http_response(delay=0.4) as (port, _):
            started = time.monotonic()
            with self.assertRaises(ReadError):
                read_descriptor("127.0.0.1", port, 0.1)
            self.assertLess(time.monotonic() - started, 0.5)


if __name__ == "__main__":
    unittest.main()
