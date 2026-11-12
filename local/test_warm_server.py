import hashlib
import json
import multiprocessing
import os
import socket
import struct
import sys
import tempfile
import time
import types
import unittest

import warm_server

COUNTER = {"n": 0}


def fake_handle(request):
    COUNTER["n"] += 1  # must never accumulate: each request is a fresh fork
    if request.get("sleep"):
        time.sleep(request["sleep"])
    if request.get("exit"):
        raise SystemExit(3)
    return {"ok": True, "result": request.get("code"), "pid": os.getpid(), "count": COUNTER["n"]}


def run_server(path, timeout_secs):
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(8)
    warm_server.serve(listener, fake_handle, timeout_secs=timeout_secs, max_frame=1024)


def call(path, payload):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(20)
    with conn:
        conn.connect(path)
        warm_server.write_frame(conn, payload)
        return json.loads(warm_server.read_frame(conn, 1 << 20))


class WarmServerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "w.sock")
        self.proc = multiprocessing.get_context("fork").Process(
            target=run_server, args=(self.path, 1)
        )
        self.proc.start()
        for _ in range(100):
            if os.path.exists(self.path):
                break
            time.sleep(0.05)

    def tearDown(self):
        self.proc.kill()
        self.proc.join()

    def test_round_trip(self):
        reply = call(self.path, json.dumps({"code": "6*7"}).encode())
        self.assertEqual(reply["ok"], True)
        self.assertEqual(reply["result"], "6*7")

    def test_every_request_gets_its_own_process_and_clean_state(self):
        first = call(self.path, b'{"code": 1}')
        second = call(self.path, b'{"code": 2}')
        self.assertNotEqual(first["pid"], second["pid"])
        self.assertNotEqual(first["pid"], self.proc.pid)
        self.assertEqual((first["count"], second["count"]), (1, 1))

    def test_non_object_and_garbage_are_refused(self):
        self.assertEqual(call(self.path, b"[1]")["ok"], False)
        self.assertIn("JSON", call(self.path, b"not json")["error"])

    def test_oversized_frame_is_refused(self):
        self.assertIn("exceeds", call(self.path, b" " * 2000)["error"])

    def test_system_exit_in_submitted_code_still_gets_an_answer(self):
        reply = call(self.path, b'{"exit": true}')
        self.assertEqual(reply["ok"], False)
        self.assertIn("SystemExit", reply["error"])

    def test_a_slow_request_times_out_with_an_answer_and_the_server_survives(self):
        reply = call(self.path, b'{"sleep": 5}')
        self.assertEqual(reply["ok"], False)
        self.assertIn("time limit", reply["error"])
        self.assertEqual(call(self.path, b'{"code": 1}')["ok"], True)


CORE_SRC = "VALUE = 'core'\n"
WORLD_SRC = "class World:\n    pass\nVALUE = 'world'\n"


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def queueing_handle(request):
    """Does what worker.py's queue_eval does: one frame to queue_addr, token inside."""
    host, _, port = request["queue_addr"].rpartition(":")
    results = []
    for job in request["jobs"]:
        body = dict(job)
        body.setdefault("queue_token", request["queue_token"])
        with socket.create_connection((host, int(port)), timeout=10) as sock:
            warm_server.write_frame(sock, json.dumps(body).encode())
            results.append(json.loads(warm_server.read_frame(sock, 1 << 20)))
    return {"ok": True, "result": "done", "replies": results}


class QueuedEvalsTest(unittest.TestCase):
    def serve_one(self, request, queue_jobs):
        parent, child = socket.socketpair()
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                warm_server.serve_one(child, queueing_handle, 20, request, queue_jobs=queue_jobs)
            finally:
                os._exit(0)
        child.close()
        with parent:
            reply = json.loads(warm_server.read_frame(parent, 1 << 20))
        os.waitpid(pid, 0)
        return reply

    def test_jobs_come_back_in_the_response_and_are_not_run_here(self):
        reply = self.serve_one({"jobs": [{"mode": "eval", "code": "world._run_reviewer_agent()", "target": "tee"}]}, 4)
        self.assertEqual(reply["replies"], [{"ok": True}])
        self.assertEqual(reply["queued_evals"], [{"mode": "eval", "code": "world._run_reviewer_agent()", "target": "tee"}])

    def test_only_eval_and_repl_with_code_are_accepted(self):
        reply = self.serve_one({"jobs": [{"mode": "reviewer", "code": "x", "target": "tee"}, {"mode": "eval", "code": "", "target": "tee"}, {"mode": "eval", "code": "1"}]}, 4)
        self.assertEqual([r["ok"] for r in reply["replies"]], [False, False, False])
        self.assertNotIn("queued_evals", reply)

    def test_a_wrong_token_is_refused(self):
        reply = self.serve_one({"jobs": [{"mode": "eval", "code": "1", "target": "tee", "queue_token": "nope"}]}, 4)
        self.assertEqual(reply["replies"][0]["ok"], False)
        self.assertNotIn("queued_evals", reply)

    def test_the_number_of_jobs_is_capped(self):
        reply = self.serve_one({"jobs": [{"mode": "eval", "code": str(i), "target": "tee"} for i in range(5)]}, 2)
        self.assertEqual([r["ok"] for r in reply["replies"]], [True, True, False, False, False])
        self.assertEqual(len(reply["queued_evals"]), 2)

    def test_off_by_default_in_serve_one_leaves_the_request_alone(self):
        parent, child = socket.socketpair()
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                warm_server.serve_one(child, lambda r: {"ok": True, "keys": sorted(r)}, 20, {"code": "1"})
            finally:
                os._exit(0)
        child.close()
        with parent:
            reply = json.loads(warm_server.read_frame(parent, 1 << 20))
        os.waitpid(pid, 0)
        self.assertEqual(reply["keys"], ["code"])


class FakeWorker:
    """Stands in for worker.py: same call shape (loaders look the helpers up by name
    at call time), with counters for what touches the 'network'."""

    def __init__(self):
        self.store = {}
        self.pointers = {"core": sha(CORE_SRC), "world": sha(WORLD_SRC)}
        self.counts = {"pointer": 0, "asset": 0, "bucket": 0}
        self.fail_pointer = False
        self.store[sha(CORE_SRC)] = CORE_SRC.encode()
        self.store[sha(WORLD_SRC)] = WORLD_SRC.encode()

    def _verified_asset(self, bucket, digest, label):
        self.counts["asset"] += 1
        body = self.store[digest]
        assert hashlib.sha256(body).hexdigest() == digest
        return body

    def load_module_from_source(self, name, source):
        module = types.ModuleType(name)
        sys.modules[name] = module
        exec(compile(source, f"<{name}>", "exec"), module.__dict__)
        return module

    def build_bucket_and_kv(self, grant, keys):
        self.counts["bucket"] += 1
        return object(), object()

    def _pointer(self, which):
        self.counts["pointer"] += 1
        if self.fail_pointer:
            raise RuntimeError("pointer unreadable")
        return self.pointers[which]

    def load_world_core_module(self, bucket):
        digest = self._pointer("core")
        return self.load_module_from_source(
            warm_server.CORE_MODULE, self._verified_asset(bucket, digest, "core").decode()
        )

    def load_world_module(self, bucket):
        digest = self._pointer("world")
        return self.load_module_from_source(
            warm_server.WORLD_MODULE, self._verified_asset(bucket, digest, "world").decode()
        )


def world_request(prefix="acct-a/"):
    return {"mode": "eval", "code": "1", "storage_grant": {"own_prefix": prefix}, "content_keys": []}


class WorldCacheTest(unittest.TestCase):
    def setUp(self):
        self.worker = FakeWorker()
        self.compiled = []

        def counting_compile(source, filename, mode):
            self.compiled.append(filename)
            return compile(source, filename, mode)

        self.make = lambda **kw: warm_server.WorldCache(self.worker, compiler=counting_compile, **kw)
        self.original_asset = self.worker._verified_asset
        self.original_loader = self.worker.load_module_from_source

    def tearDown(self):
        for name in (warm_server.CORE_MODULE, warm_server.WORLD_MODULE):
            sys.modules.pop(name, None)

    def test_second_request_skips_asset_fetches_and_compiles_but_rereads_pointers(self):
        cache = self.make()
        self.assertIsNotNone(cache.prepare(world_request()))
        self.assertEqual((self.worker.counts["asset"], len(self.compiled)), (2, 2))
        self.assertIsNotNone(cache.prepare(world_request()))
        self.assertEqual((self.worker.counts["asset"], len(self.compiled)), (2, 2))
        # live-swap semantics: the pointers are read again on every request
        self.assertEqual(self.worker.counts["pointer"], 4)

    def test_a_repointed_world_is_picked_up_on_the_very_next_request(self):
        cache = self.make()
        cache.prepare(world_request())
        new_src = "VALUE = 'world v2'\n"
        self.worker.store[sha(new_src)] = new_src.encode()
        self.worker.pointers["world"] = sha(new_src)
        setup = cache.prepare(world_request())
        self.assertEqual(self.worker.counts["asset"], 3)  # only the new world.py was fetched
        setup()
        self.assertEqual(self.worker.load_world_module(None).VALUE, "world v2")

    def test_the_child_builds_its_modules_from_the_cache_without_touching_storage(self):
        cache = self.make()
        setup = cache.prepare(world_request())
        before = dict(self.worker.counts)
        setup()
        core = self.worker.load_world_core_module(None)
        world = self.worker.load_world_module(None)
        self.assertEqual((core.VALUE, world.VALUE), ("core", "world"))
        self.assertIs(sys.modules[warm_server.CORE_MODULE], core)
        self.assertEqual(self.worker.counts, before)

    def test_account_scope_does_not_share_entries_between_accounts(self):
        cache = self.make(scope="account")
        cache.prepare(world_request("acct-a/"))
        cache.prepare(world_request("acct-b/"))
        self.assertEqual(self.worker.counts["asset"], 4)  # b had to prove access itself

    def test_global_scope_shares_entries_between_accounts(self):
        cache = self.make(scope="global")
        cache.prepare(world_request("acct-a/"))
        cache.prepare(world_request("acct-b/"))
        self.assertEqual(self.worker.counts["asset"], 2)

    def test_unknown_scope_is_refused(self):
        with self.assertRaises(ValueError):
            self.make(scope="everyone")

    def test_a_failed_preparation_returns_no_setup_and_restores_the_worker(self):
        cache = self.make()
        self.worker.fail_pointer = True
        self.assertIsNone(cache.prepare(world_request()))
        self.assertEqual(self.worker._verified_asset, self.original_asset)
        self.assertEqual(self.worker.load_module_from_source, self.original_loader)

    def test_worldless_requests_are_left_alone(self):
        cache = self.make()
        request = world_request()
        request["world"] = False
        self.assertIsNone(cache.prepare(request))
        self.assertEqual(self.worker.counts, {"pointer": 0, "asset": 0, "bucket": 0})

    def test_the_cache_is_bounded(self):
        cache = self.make(max_entries=2)
        for i in range(4):
            src = f"VALUE = {i}\n"
            self.worker.store[sha(src)] = src.encode()
            self.worker.pointers["world"] = sha(src)
            cache.prepare(world_request())
        self.assertLessEqual(len(cache.assets), 2)
        self.assertLessEqual(len(cache.codes), 2)

    def test_a_tampered_asset_is_still_refused_on_first_fetch(self):
        cache = self.make()
        self.worker.store[sha(WORLD_SRC)] = b"VALUE = 'evil'\n"
        # The core was genuine and may be cached; the tampered world.py must not be.
        self.assertIsNone(cache.prepare(world_request()))  # the hash check failed
        self.assertNotIn(("acct-a/", sha(WORLD_SRC)), cache.assets)
        self.assertEqual(len(cache.codes), 1)


PARENT = {"n": 0}
CHILD = {"n": None}


def run_prepared_server(path, explode):
    def prepare(request):
        if explode and request.get("explode"):
            raise RuntimeError("prepare failed")
        PARENT["n"] += 1
        n = PARENT["n"]
        return lambda: CHILD.update(n=n)

    def handle(request):
        return {"ok": True, "n": CHILD["n"], "pid": os.getpid()}

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(8)
    warm_server.serve(listener, handle, timeout_secs=5, max_frame=1024, prepare=prepare,
                      prep_timeout=5, read_timeout=0.5)


class FakeKv:
    def __init__(self, data, delay=0.0, fail=()):
        self.data, self.delay, self.fail, self.reads = data, delay, set(fail), []

    def kv_get(self, key):
        self.reads.append(key)
        time.sleep(self.delay)
        if key in self.fail:
            raise OSError("storage down")
        return (self.data.get(key), key in self.data)


class ConcurrentPrepareTest(unittest.TestCase):
    """The parent issues the pointer reads and the prefetched key reads together, and hands the latter to the child."""

    def setUp(self):
        self.worker = FakeWorker()
        self.kv = FakeKv({"circle.review.next": "1700000000"}, delay=0.0)
        self.worker.build_bucket_and_kv = lambda grant, keys: (object(), self.kv)
        self.keys = ("circle.review.interval", "circle.review.next")

    def tearDown(self):
        for name in (warm_server.CORE_MODULE, warm_server.WORLD_MODULE):
            sys.modules.pop(name, None)

    def cache(self):
        return warm_server.WorldCache(self.worker, prefetch_keys=self.keys)

    def test_loaders_and_reads_overlap(self):
        delay = 0.3
        original_pointer = self.worker._pointer

        def slow_pointer(which):
            time.sleep(delay)
            return original_pointer(which)

        self.worker._pointer = slow_pointer
        self.kv.delay = delay
        started = time.monotonic()
        self.assertIsNotNone(self.cache().prepare(world_request()))
        elapsed = time.monotonic() - started
        # two pointers + two key reads, each 0.3 s: sequential would be >= 1.2 s
        self.assertLess(elapsed, 0.9)

    def test_the_child_gets_each_prefetched_key_once_then_reads_the_store(self):
        setup = self.cache().prepare(world_request())
        self.assertEqual(sorted(self.kv.reads), sorted(self.keys))  # the parent read them
        setup()
        _bucket, child_kv = self.worker.build_bucket_and_kv({}, [])
        self.kv.reads.clear()
        self.assertEqual(child_kv.kv_get("circle.review.next"), ("1700000000", True))
        self.assertEqual(child_kv.kv_get("circle.review.interval"), (None, False))
        self.assertEqual(self.kv.reads, [])  # served from the prefetch
        self.kv.data["circle.review.next"] = "1800000000"  # a write after the first read must be seen
        self.assertEqual(child_kv.kv_get("circle.review.next"), ("1800000000", True))
        self.assertEqual(self.kv.reads, ["circle.review.next"])
        self.assertEqual(child_kv.kv_get("other"), (None, False))

    def test_a_failed_prefetch_is_not_fatal_and_falls_back_to_a_real_read(self):
        self.kv.fail = {"circle.review.next"}
        setup = self.cache().prepare(world_request())
        self.assertIsNotNone(setup)
        setup()
        _bucket, child_kv = self.worker.build_bucket_and_kv({}, [])
        self.kv.fail = set()
        self.kv.reads.clear()
        self.assertEqual(child_kv.kv_get("circle.review.next"), ("1700000000", True))
        self.assertEqual(self.kv.reads, ["circle.review.next"])
        self.assertEqual(child_kv.kv_get("circle.review.interval"), (None, False))  # this one was prefetched

    def test_a_loader_failure_means_no_setup(self):
        self.worker.fail_pointer = True
        self.assertIsNone(self.cache().prepare(world_request()))

    def test_without_prefetch_keys_nothing_is_wrapped(self):
        setup = warm_server.WorldCache(self.worker).prepare(world_request())
        self.assertEqual(self.kv.reads, [])
        original = self.worker.build_bucket_and_kv
        setup()
        self.assertIs(self.worker.build_bucket_and_kv, original)


class PreparedServeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "w.sock")
        self.proc = multiprocessing.get_context("fork").Process(
            target=run_prepared_server, args=(self.path, True))
        self.proc.start()
        for _ in range(100):
            if os.path.exists(self.path):
                break
            time.sleep(0.05)

    def tearDown(self):
        self.proc.kill()
        self.proc.join()

    def test_prepare_runs_in_the_parent_and_its_state_persists_across_requests(self):
        first = call(self.path, b"{}")
        second = call(self.path, b"{}")
        self.assertEqual((first["n"], second["n"]), (1, 2))
        self.assertNotEqual(first["pid"], second["pid"])

    def test_a_failing_prepare_does_not_stop_the_request(self):
        reply = call(self.path, b'{"explode": true}')
        self.assertEqual(reply["ok"], True)
        self.assertIsNone(reply["n"])  # no setup ran, the child took the normal path

    def test_a_client_that_never_sends_does_not_block_the_next_one(self):
        stalled = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stalled.connect(self.path)
        started = time.time()
        reply = call(self.path, b"{}")
        stalled.close()
        self.assertEqual(reply["ok"], True)
        self.assertLess(time.time() - started, 5)


if __name__ == "__main__":
    unittest.main()
