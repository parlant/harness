"""Self-tests for FakeDaemon, PtySession, and baseline `h` wire compatibility."""

from __future__ import annotations

import http.client
import json
import os
import socket
import sys
import tempfile
import threading
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, "..", "..", ".."))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from fake_daemon import FakeDaemon, extract_content_text  # noqa: E402
from pty_harness import PtySession, find_h_binary, strip_ansi  # noqa: E402


class _UdsHttpConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str) -> None:
        super().__init__("localhost")
        self._socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(self._socket_path)
        self.sock = sock


class FakeDaemonTests(unittest.TestCase):
    def test_uds_auth_and_session_detail_and_idempotent_commands(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hi-self-", dir="/tmp") as cwd:
            with FakeDaemon(transport="uds", cwd=cwd, session_id="demo") as daemon:
                assert daemon.socket_path is not None

                # Missing bearer token -> 401
                conn = _UdsHttpConnection(daemon.socket_path)
                conn.request("GET", "/api/v1/sessions/demo", headers={"Host": "localhost"})
                resp = conn.getresponse()
                resp.read()
                self.assertEqual(resp.status, 401)
                conn.close()

                # Valid bearer token -> 200
                conn = _UdsHttpConnection(daemon.socket_path)
                headers = {
                    "Host": "localhost",
                    "Authorization": f"Bearer {daemon.token}",
                    "Content-Type": "application/json",
                }
                conn.request("GET", "/api/v1/sessions/demo", headers=headers)
                resp = conn.getresponse()
                detail = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(resp.status, 200)
                self.assertEqual(detail["session"]["session_id"], "demo")
                self.assertEqual(detail["conversations"][0]["id"], "1")
                conn.close()

                # Idempotent command replay vs conflict
                env_payload = {
                    "version": 1,
                    "request_id": "req-1",
                    "conversation_id": 1,
                    "command": "configure",
                    "args": {"thinking": "high"},
                }
                conn = _UdsHttpConnection(daemon.socket_path)
                conn.request(
                    "POST",
                    "/api/v1/sessions/demo/commands",
                    body=json.dumps(env_payload),
                    headers=headers,
                )
                r1 = conn.getresponse()
                d1 = json.loads(r1.read().decode("utf-8"))
                self.assertEqual(r1.status, 200)
                conn.close()

                conn = _UdsHttpConnection(daemon.socket_path)
                conn.request(
                    "POST",
                    "/api/v1/sessions/demo/commands",
                    body=json.dumps(env_payload),
                    headers=headers,
                )
                r2 = conn.getresponse()
                d2 = json.loads(r2.read().decode("utf-8"))
                self.assertEqual(r2.status, 200)
                self.assertEqual(d1, d2)
                conn.close()

                env_conflict = dict(env_payload, args={"thinking": "low"})
                conn = _UdsHttpConnection(daemon.socket_path)
                conn.request(
                    "POST",
                    "/api/v1/sessions/demo/commands",
                    body=json.dumps(env_conflict),
                    headers=headers,
                )
                r3 = conn.getresponse()
                r3.read()
                self.assertEqual(r3.status, 409)
                conn.close()

    def test_tcp_host_validation_and_gated_steer_followup_sse(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hi-tcp-", dir="/tmp") as cwd:
            with FakeDaemon(transport="tcp", cwd=cwd, session_id="demo") as daemon:
                assert daemon.port is not None

                # Wrong Host header -> 421
                conn = http.client.HTTPConnection("127.0.0.1", daemon.port, timeout=3)
                conn.request(
                    "GET",
                    "/api/v1/models",
                    headers={
                        "Host": "evil.example:80",
                        "Authorization": f"Bearer {daemon.token}",
                    },
                )
                bad = conn.getresponse()
                bad.read()
                self.assertEqual(bad.status, 421)
                conn.close()

                # Open SSE stream
                sse_conn = http.client.HTTPConnection("127.0.0.1", daemon.port, timeout=5)
                sse_conn.request(
                    "GET",
                    "/api/v1/sessions/demo/conversations/1/events",
                    headers={
                        "Host": f"127.0.0.1:{daemon.port}",
                        "Authorization": f"Bearer {daemon.token}",
                    },
                )
                sse_resp = sse_conn.getresponse()
                self.assertEqual(sse_resp.status, 200)

                gate = daemon.arm_gated_stream(chunks=["chunk-a ", "chunk-b "])
                headers = {
                    "Host": f"127.0.0.1:{daemon.port}",
                    "Authorization": f"Bearer {daemon.token}",
                    "Content-Type": "application/json",
                }
                c_conn = http.client.HTTPConnection("127.0.0.1", daemon.port, timeout=3)
                c_conn.request(
                    "POST",
                    "/api/v1/sessions/demo/commands",
                    body=json.dumps(
                        {
                            "version": 1,
                            "request_id": "s1",
                            "conversation_id": 1,
                            "command": "submit",
                            "args": {
                                "type": "input",
                                "content": [{"type": "text", "text": "hello"}],
                                "when_busy": "steer",
                                "when_idle": "start",
                            },
                        }
                    ),
                    headers=headers,
                )
                self.assertEqual(c_conn.getresponse().status, 200)
                c_conn.close()

                daemon.wait_for_stream_active("demo", "1", min_ephemerals=2, timeout=3.0)
                gate.set()
                daemon.wait_for_turn_idle("demo", "1", timeout=3.0)

                entries = daemon.conversation_entries("demo", "1")
                self.assertEqual([e["kind"] for e in entries], ["user", "assistant"])
                self.assertEqual(
                    extract_content_text(entries[1]["data"]["content"]),
                    "chunk-a chunk-b ",
                )
                sse_conn.close()

    def test_steer_and_follow_up_and_replay_ring(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hi-queue-", dir="/tmp") as cwd:
            with FakeDaemon(transport="uds", cwd=cwd, session_id="demo") as daemon:
                assert daemon.socket_path is not None
                headers = {
                    "Host": "localhost",
                    "Authorization": f"Bearer {daemon.token}",
                    "Content-Type": "application/json",
                }
                gate = daemon.arm_gated_stream(chunks=["turn1"])

                # Start turn 1
                c1 = _UdsHttpConnection(daemon.socket_path)
                c1.request(
                    "POST",
                    "/api/v1/sessions/demo/commands",
                    body=json.dumps(
                        {
                            "version": 1,
                            "request_id": "q1",
                            "conversation_id": 1,
                            "command": "submit",
                            "args": {
                                "type": "input",
                                "content": "p1",
                                "when_busy": "steer",
                                "when_idle": "start",
                            },
                        }
                    ),
                    headers=headers,
                )
                self.assertEqual(c1.getresponse().status, 200)
                c1.close()

                daemon.wait_for_stream_active("demo", "1", min_ephemerals=1, timeout=3.0)

                # Enqueue follow_up then steer while busy; steer goes ahead of follow_up.
                for rid, text, mode in [
                    ("q2", "later", "follow_up"),
                    ("q3", "urgent", "steer"),
                ]:
                    cx = _UdsHttpConnection(daemon.socket_path)
                    cx.request(
                        "POST",
                        "/api/v1/sessions/demo/commands",
                        body=json.dumps(
                            {
                                "version": 1,
                                "request_id": rid,
                                "conversation_id": 1,
                                "command": "submit",
                                "args": {
                                    "type": "input",
                                    "content": text,
                                    "when_busy": mode,
                                    "when_idle": "start",
                                },
                            }
                        ),
                        headers=headers,
                    )
                    r = cx.getresponse()
                    body = json.loads(r.read().decode("utf-8"))
                    self.assertEqual(r.status, 200)
                    self.assertEqual(body["status"], "queued")
                    cx.close()

                gate.set()
                daemon.wait_for_turn_idle("demo", "1", timeout=5.0)

                user_texts = [
                    extract_content_text(e["data"]["content"])
                    for e in daemon.conversation_entries("demo", "1")
                    if e["kind"] == "user"
                ]
                self.assertEqual(user_texts, ["p1", "urgent", "later"])

                # Verify Last-Event-ID replay returns commit frames rather than snapshot.
                sse = _UdsHttpConnection(daemon.socket_path)
                sse.request(
                    "GET",
                    "/api/v1/sessions/demo/conversations/1/events",
                    headers={
                        "Host": "localhost",
                        "Authorization": f"Bearer {daemon.token}",
                        "Last-Event-ID": "1",
                    },
                )
                sresp = sse.getresponse()
                self.assertEqual(sresp.status, 200)
                first_chunk = sresp.read1(1024).decode("utf-8", errors="replace")
                self.assertIn("event: commit", first_chunk)
                sse.close()


class PtyHarnessTests(unittest.TestCase):
    def test_pty_raw_restore_alt_enter_and_resize(self) -> None:
        script = (
            "import os, signal, sys, termios, tty\n"
            "fd = sys.stdin.fileno()\n"
            "old = termios.tcgetattr(fd)\n"
            "got_winch = [False]\n"
            "signal.signal(signal.SIGWINCH, lambda *_: got_winch.__setitem__(0, True))\n"
            "try:\n"
            "    tty.setraw(fd)\n"
            "    sys.stdout.write('\\x1b[?1049hREADY\\r\\n')\n"
            "    sys.stdout.flush()\n"
            "    buf = bytearray()\n"
            "    while True:\n"
            "        b = os.read(fd, 64)\n"
            "        if not b:\n"
            "            break\n"
            "        buf.extend(b)\n"
            "        if b'\\x1b\\r' in buf:\n"
            "            sys.stdout.write('ALT_ENTER\\r\\n')\n"
            "            sys.stdout.flush()\n"
            "            break\n"
            "finally:\n"
            "    termios.tcsetattr(fd, termios.TCSADRAIN, old)\n"
            "    sys.stdout.write(f'\\x1b[?1049lWINCH={got_winch[0]}\\n')\n"
            "    sys.stdout.flush()\n"
        )
        with PtySession([sys.executable, "-c", script], rows=24, cols=80) as pty:
            pty.wait_for_output("READY", timeout=3.0)
            self.assertTrue(pty.is_raw_mode())
            pty.resize(30, 100)
            pty.send_alt_enter()
            pty.wait_for_output("ALT_ENTER", timeout=3.0)
            rc = pty.wait(timeout=3.0)
            self.assertEqual(rc, 0)
            self.assertTrue(pty.is_cooked_mode())
            self.assertIn("WINCH=True", pty.clean_text())
            self.assertIn("\x1b[?1049h", pty.raw_text())
            self.assertIn("\x1b[?1049l", pty.raw_text())

    def test_strip_ansi_removes_csi_and_osc(self) -> None:
        raw = "\x1b[?1049h\x1b]0;title\x07\x1b[32mhello\x1b[0m world\x1b[?1049l"
        self.assertEqual(strip_ansi(raw), "hello world")


class BaselineHCompatibilityTests(unittest.TestCase):
    def test_existing_h_binary_works_against_fake_daemon_if_built(self) -> None:
        h_bin = find_h_binary(REPO_ROOT)
        if not h_bin:
            self.skipTest("baseline `h` binary not built; skipping baseline compatibility check")

        with tempfile.TemporaryDirectory(prefix="hi-hbase-", dir="/tmp") as cwd:
            with FakeDaemon(transport="uds", cwd=cwd, session_id="demo") as daemon:
                daemon.arm_auto_stream(chunks=["Hello from fake daemon"])
                with PtySession(
                    [h_bin, "-s", "demo", "-p", "ping"],
                    env=daemon.env(),
                    cwd=cwd,
                ) as pty:
                    rc = pty.wait(timeout=5.0)
                    self.assertEqual(rc, 0, f"h -p failed; out={pty.clean_text()!r}")
                    self.assertIn("Hello from fake daemon", pty.clean_text())
                self.assertEqual(daemon.abort_commands(), [])

            with FakeDaemon(transport="tcp", cwd=cwd, session_id="demo") as daemon:
                with PtySession(
                    [h_bin, "-s", "demo"],
                    env=daemon.env(),
                    cwd=cwd,
                ) as pty:
                    daemon.wait_for_sse_connect("demo", "1", timeout=5.0)
                    pty.wait_for_output("H session demo", timeout=5.0)
                    pty.send_text("/quit\n")
                    self.assertEqual(pty.wait(timeout=5.0), 0)
                self.assertEqual(daemon.abort_commands(), [])


if __name__ == "__main__":
    unittest.main()
