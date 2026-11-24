from datetime import datetime, timedelta, timezone
import unittest

from rebecca_pet.state import Failure, Reducer, Request, Run, Snapshot, Thread


T0 = datetime(2026, 11, 25, tzinfo=timezone.utc)


def run(status="running", run_id="r1", thread_id="t1", requested=-30):
    return Run(thread_id, run_id, status, T0 + timedelta(seconds=requested))


def sample(seconds=0, runs=(), requests=(), service="server-1", scope=(), extra=()):
    return Snapshot(T0 + timedelta(seconds=seconds), service, "0.1.11",
                    (Thread("t1", "p1", tuple(runs), tuple(requests)), *extra), scope)


class ReducerTests(unittest.TestCase):
    def test_startup_does_not_replay_history(self):
        result = Reducer().reduce(sample(runs=[run("completed")]))
        self.assertEqual(result["state"], "idle")
        self.assertIsNone(result["event"])

    def test_historical_failure_does_not_permanently_cover_activity(self):
        result = Reducer().reduce(sample(runs=[run("failed")]))
        self.assertEqual(result["state"], "idle")
        self.assertEqual(result["counts"]["failed"], 1)

    def test_waiting_is_work_not_approval(self):
        result = Reducer().reduce(sample(runs=[run("waiting")]))
        self.assertEqual(result["state"], "working")
        self.assertEqual(result["counts"]["waiting_user"], 0)

    def test_async_request_keeps_working(self):
        result = Reducer().reduce(sample(runs=[run()], requests=[Request("q", "t1", "user_input", False)]))
        self.assertEqual(result["state"], "working")
        self.assertEqual(result["counts"], {"working": 1, "waiting_user": 0, "pending": 1, "failed": 0})

    def test_blocking_request_is_attention(self):
        result = Reducer().reduce(sample(runs=[run("waiting")], requests=[Request("q", "t1", "command", True)]))
        self.assertEqual(result["state"], "attention")
        self.assertEqual(result["counts"]["working"], 0)

    def test_unknown_blocking_does_not_claim_user_stop(self):
        result = Reducer().reduce(sample(runs=[run()], requests=[Request("q", "t1", "user_input", None)]))
        self.assertEqual(result["state"], "working")
        self.assertEqual(result["counts"]["pending"], 1)

    def test_internal_request_is_not_user_approval(self):
        result = Reducer().reduce(sample(runs=[run()], requests=[Request("q", "t1", "auth_refresh", True)]))
        self.assertEqual(result["state"], "working")
        self.assertEqual(result["counts"]["waiting_user"], 0)

    def test_child_and_parent_count_as_one_top_level_task(self):
        result = Reducer().reduce(sample(runs=[run(), run(thread_id="child")]))
        self.assertEqual(result["counts"]["working"], 1)

    def test_working_parent_and_blocked_child_can_coexist(self):
        result = Reducer().reduce(sample(runs=[run(), run(thread_id="child")],
                                         requests=[Request("q", "child", "permission", True)]))
        self.assertEqual(result["state"], "attention")
        self.assertEqual(result["counts"]["working"], 1)
        self.assertEqual(result["counts"]["waiting_user"], 1)

    def test_success_event_stays_stable_then_expires(self):
        reducer = Reducer()
        reducer.reduce(sample(runs=[run()]))
        first = reducer.reduce(sample(1, [run("completed")]))
        repeat = reducer.reduce(sample(2, [run("completed")]))
        self.assertEqual(first["state"], "success")
        self.assertEqual(first["event"], repeat["event"])
        self.assertEqual(reducer.reduce(sample(6, [run("completed")]))["state"], "idle")

    def test_offline_resets_baseline_and_overrides_activity(self):
        reducer = Reducer()
        reducer.reduce(sample(runs=[run()]))
        unavailable = reducer.reduce(Failure("offline", "test", "Unavailable"), now=T0 + timedelta(seconds=1))
        self.assertEqual(unavailable["state"], "offline")
        self.assertIsInstance(unavailable["source"]["version"], str)
        self.assertEqual(reducer.reduce(sample(2, [run("completed")]))["state"], "idle")

    def test_service_restart_rebuilds_baseline(self):
        reducer = Reducer()
        reducer.reduce(sample(runs=[run()]))
        self.assertIsNone(reducer.reduce(sample(1, [run("completed")], service="server-2"))["event"])

    def test_scope_change_rebuilds_baseline(self):
        reducer = Reducer()
        reducer.reduce(sample(runs=[run()]))
        self.assertIsNone(reducer.reduce(sample(1, [run("completed")], scope=("p1",)))["event"])

    def test_fast_new_run_completion_is_seen(self):
        reducer = Reducer()
        reducer.reduce(sample())
        result = reducer.reduce(sample(2, [run("completed", "fast", requested=1)]))
        self.assertEqual(result["state"], "success")

    def test_unseen_old_run_completion_is_not_replayed(self):
        reducer = Reducer()
        reducer.reduce(sample())
        self.assertIsNone(reducer.reduce(sample(2, [run("completed", "old")]))["event"])

    def test_stopped_states_are_not_success(self):
        for status in ("interrupted", "cancelled", "rolled_back"):
            with self.subTest(status=status):
                reducer = Reducer()
                reducer.reduce(sample(runs=[run()]))
                self.assertEqual(reducer.reduce(sample(1, [run(status)]))["state"], "stopped")

    def test_rollback_after_completed_is_new_stop(self):
        reducer = Reducer()
        reducer.reduce(sample(runs=[run("completed")]))
        self.assertEqual(reducer.reduce(sample(1, [run("rolled_back")]))["state"], "stopped")

    def test_new_failure_has_priority_over_working_and_success(self):
        reducer = Reducer()
        reducer.reduce(sample(runs=[run()]))
        extra = (Thread("t2", "p1", (run(thread_id="t2"),)),)
        self.assertEqual(reducer.reduce(sample(1, [run("failed")], extra=extra))["state"], "error")
        self.assertEqual(reducer.reduce(sample(7, [run("failed")], extra=extra))["state"], "working")

    def test_returning_previously_seen_run_not_replayed(self):
        reducer = Reducer()
        reducer.reduce(sample())
        reducer.reduce(sample(2, [run("completed", "fast", requested=1)]))
        reducer.reduce(sample(10))
        self.assertIsNone(reducer.reduce(sample(11, [run("completed", "fast", requested=1)]))["event"])

    def test_unknown_run_status_fails_explicitly(self):
        result = Reducer().reduce(sample(runs=[run("future_status")]))
        self.assertEqual(result["state"], "incompatible")
        self.assertEqual(result["source"]["health"], "incompatible")


if __name__ == "__main__":
    unittest.main()
