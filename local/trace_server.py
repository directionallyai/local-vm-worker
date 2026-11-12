#!/usr/bin/env python3
"""Tracing launcher for warm_server.py (DEV ANALYSIS ONLY, UNATTESTED).

Runs the warm worker exactly as `python3 warm_server.py` would, with timing
wrappers around the parts that cost time, and prints one `TRACE {json}` line per
request side (the warm parent, then the forked child) to stdout:

  - the parent's steps: reading the request, the world-code preparation, and
    every HTTPS request it makes;
  - the child's steps: the same, plus worker.handle's own phase timings;
  - for every HTTPS request, how long it spent connecting (TCP), in the TLS
    handshake, waiting for response headers, and reading the body;
  - CPU time next to wall time, so waiting and computing can be told apart.

Request labels carry only the kind of object and its key name (for example
`kv circle.world_py`), never the account prefix, a credential or any payload.
Same environment variables as warm_server.py.
"""

import http.client
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import warm_server  # noqa: E402

STATE = {"req": 0, "t0": time.perf_counter(), "cpu0": time.process_time(), "events": []}


def now():
    return time.perf_counter() - STATE["t0"]


def record(kind, label, started, **extra):
    STATE["events"].append(
        {"kind": kind, "label": label, "at": round(started - STATE["t0"], 3),
         "dur": round(time.perf_counter() - started, 3), **extra}
    )


def wrap(owner, name, kind, label=lambda *a, **k: ""):
    original = getattr(owner, name)

    def wrapper(*args, **kwargs):
        started = time.perf_counter()
        try:
            return original(*args, **kwargs)
        finally:
            record(kind, label(*args, **kwargs), started)

    setattr(owner, name, wrapper)
    return original


def describe(request):
    """Method plus the kind of object and its key name, never the account prefix."""
    try:
        url = request.full_url if hasattr(request, "full_url") else str(request)
        path = urllib.parse.urlparse(url).path
        method = request.get_method() if hasattr(request, "get_method") else "GET"
    except Exception:
        return "?"
    for marker, kind in (("/kv/", "kv"), ("/assets/", "asset"), ("/keys/", "keys")):
        if marker in path:
            return f"{method} {kind} {path.split(marker, 1)[1][:48]}"
    return f"{method} other ({len(path)} chars)"


def emit(side, extra=None):
    wall = now()
    cpu = time.process_time() - STATE["cpu0"]
    line = {"req": STATE["req"], "side": side, "wall": round(wall, 3), "cpu": round(cpu, 3),
            "t_end": time.time(), "t_start": STATE.get("abs0"), "events": STATE["events"]}
    line.update(extra or {})
    print("TRACE " + json.dumps(line), flush=True)


def install():
    socket.create_connection = _timed_function(socket, "create_connection", "tcp")
    wrap(ssl.SSLContext, "wrap_socket", "tls")
    wrap(http.client.HTTPConnection, "getresponse", "wait")
    wrap(http.client.HTTPResponse, "read", "body")
    original_urlopen = urllib.request.urlopen

    def traced_urlopen(request, *args, **kwargs):
        started = time.perf_counter()
        status = None
        try:
            response = original_urlopen(request, *args, **kwargs)
            status = getattr(response, "status", None)
            return response
        except urllib.error.HTTPError as exc:
            status = exc.code
            raise
        finally:
            record("http", describe(request), started, status=status)

    urllib.request.urlopen = traced_urlopen

    original_read = warm_server._read_request
    original_prepare = warm_server._prepare_in_parent
    original_serve_one = warm_server.serve_one

    def traced_read(conn, max_frame):
        STATE.update(req=STATE["req"] + 1, t0=time.perf_counter(), cpu0=time.process_time(), events=[], abs0=time.time())
        started = time.perf_counter()
        try:
            return original_read(conn, max_frame)
        finally:
            record("read", "request frame", started)

    def traced_prepare(prepare, request, prep_timeout):
        started = time.perf_counter()
        try:
            return original_prepare(prepare, request, prep_timeout)
        finally:
            record("prepare", "parent world-code step", started)
            emit("parent")

    def traced_serve_one(conn, handle, timeout_secs, request, setup=None):
        STATE.update(t0=time.perf_counter(), cpu0=time.process_time(), events=[], abs0=time.time())
        captured = {}

        def traced_handle(req):
            started = time.perf_counter()
            response = handle(req)
            record("handle", "worker.handle", started)
            captured["timings"] = {k: round(v, 3) for k, v in (response.get("timings") or {}).items()}
            return response

        original_serve_one(conn, traced_handle, timeout_secs, request, setup)
        emit("child", {"phases": captured.get("timings", {})})

    warm_server._read_request = traced_read
    warm_server._prepare_in_parent = traced_prepare
    warm_server.serve_one = traced_serve_one


def _timed_function(owner, name, kind):
    original = getattr(owner, name)

    def wrapper(*args, **kwargs):
        started = time.perf_counter()
        try:
            return original(*args, **kwargs)
        finally:
            record(kind, "", started)

    return wrapper


if __name__ == "__main__":
    install()
    warm_server.main()
