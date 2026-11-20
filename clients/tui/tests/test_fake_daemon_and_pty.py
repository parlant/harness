"""Focused self-tests for FakeDaemon, PtySession, and binary discovery."""

from __future__ import annotations

import http.client
import json
import os
import socket
import sys
import tempfile
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, "..", "..", ".."))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from fake_daemon import FakeDaemon, extract_content_text  # noqa: E402
from pty_harness import PtySession, find_hi_binary, strip_ansi  # noqa: E402


class _UdsHttpConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str) -> None:
        super().__init__("localhost")
        self._socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(self._socket_path)
        self.sock = sock


class FakeDaemonTests(unittest.TestCase):
    def test_uds_auth_and_session_detail(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hi-self-", dir="/tmp") as cwd:
            with FakeDaemon(transport="uds", cwd=cwd, session_id="demo") as daemon:
                assert daemon.socket_path is not None

                conn = _UdsHttpConnection(daemon.socket_path)
                conn.request("GET", "/api/v1/sessions/demo", headers={"Host": "localhost"})
                resp = conn.getresponse()
                resp.read()
                self.assertEqual(resp.status, 401)
                conn.close()

                conn = _UdsHttpConnection(daemon.socket_path)
                conn.request(
                    "GET",
                    "/api/v1/sessions/demo",
                    headers={"Host": "localhost", "Authorization": f"Bearer {daemon.token}"},
                )
                resp = conn.getresponse()
                detail = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(resp.status, 200)
                self.assertEqual(detail["session"]["session_id"], "demo")
                conn.close()

    def test_tcp_host_validation_and_steer_followup_order(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hi-tcp-", dir="/tmp") as cwd:
            with FakeDaemon(transport="tcp", cwd=cwd, session_id="demo") as daemon:
                assert daemon.port is not None
                bad = http.client.HTTPConnection("127.0.0.1", daemon.port, timeout=3)
                bad.request(
                    "GET",
                    "/api/v1/sessions/demo",
                    headers={"Host": "evil.example:80", "Authorization": f"Bearer {daemon.token}"},
                )
                bresp = bad.getresponse()
                bresp.read()
                self.assertEqual(bresp.status, 421)
                bad.close()

                headers = {
                    "Host": f"127.0.0.1:{daemon.port}",
                    "Authorization": f"Bearer {daemon.token}",
                    "Content-Type": "application/json",
                }
                gate = daemon.arm_gated_stream(chunks=["turn1"])
                for rid, text, mode in [
                    ("r1", "p1", "steer"),
                    ("r2", "later", "follow_up"),
                    ("r3", "urgent", "steer"),
                ]:
                    if rid == "r2":
                        daemon.wait_for_stream_active(min_ephemerals=1, timeout=3.0)
                    c = http.client.HTTPConnection("127.0.0.1", daemon.port, timeout=3)
                    c.request(
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
                    self.assertEqual(c.getresponse().status, 200)
                    c.close()

                gate.set()
                daemon.wait_for_turn_idle(timeout=5.0)
                user_texts = [
                    extract_content_text(e["data"]["content"])
                    for e in daemon.conversation_entries()
                    if e["kind"] == "user"
                ]
                self.assertEqual(user_texts, ["p1", "urgent", "later"])


class PtyHarnessTests(unittest.TestCase):
    def test_find_binary_never_uses_unrelated_path_binary(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hi-path-", dir="/tmp") as fake_path:
            fake_hi = os.path.join(fake_path, "hi")
            with open(fake_hi, "w", encoding="utf-8") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(fake_hi, 0o755)

            old_env = {k: os.environ.get(k) for k in ("HI_BIN", "CARGO_TARGET_DIR", "PATH")}
            try:
                os.environ.pop("HI_BIN", None)
                os.environ["CARGO_TARGET_DIR"] = os.path.join(fake_path, "empty-target")
                os.environ["PATH"] = fake_path
                self.assertIsNone(find_hi_binary(os.path.join(fake_path, "empty-repo")))
            finally:
                for k, v in old_env.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v

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
            pty.wait_for_output("WINCH=True", timeout=3.0)
            self.assertEqual(pty.wait(timeout=3.0), 0)
            self.assertTrue(pty.is_cooked_mode())
            self.assertIn("ALT_ENTER", pty.clean_text())
            self.assertIn("\x1b[?1049h", pty.raw_text())
            self.assertIn("\x1b[?1049l", pty.raw_text())

    def test_strip_ansi_removes_csi_and_osc(self) -> None:
        raw = "\x1b[?1049h\x1b]0;title\x07\x1b[32mhello\x1b[0m world\x1b[?1049l"
        self.assertEqual(strip_ansi(raw), "hello world")

    def test_pty_hangup_terminates_raw_session_leader_without_blocked_master_fd(self) -> None:
        with PtySession(["/bin/sh", "-c", "stty raw -echo; printf READY; sleep 10"]) as pty:
            pty.wait_for_output("READY", timeout=3.0)
            self.assertTrue(pty.is_raw_mode())
            pty.close_master_hangup()
            rc = pty.wait(timeout=3.0)
            self.assertNotEqual(rc, None)


class BaselineHiPrintCompatibilityTests(unittest.TestCase):
    def test_hi_print_mode_works_against_fake_daemon_over_uds_and_tcp(self) -> None:
        hi_bin = find_hi_binary(REPO_ROOT)
        if not hi_bin:
            if os.environ.get("HI_PTY_REQUIRE_BIN") == "1":
                self.fail("hi binary not built; set HI_BIN=/path/to/hi")
            self.skipTest("hi binary not built; skipping print compatibility check")

        with tempfile.TemporaryDirectory(prefix="hi-pbase-", dir="/tmp") as cwd:
            for transport in ("uds", "tcp"):
                with self.subTest(transport=transport):
                    with FakeDaemon(transport=transport, cwd=cwd, session_id="demo") as daemon:
                        daemon.arm_auto_stream(chunks=["Hello from fake daemon"])
                        with PtySession([hi_bin, "-s", "demo", "-p", "ping"], env=daemon.env(), cwd=cwd) as pty:
                            self.assertEqual(pty.wait(timeout=5.0), 0)
                            self.assertIn("Hello from fake daemon", pty.clean_text())
                            self.assertNotIn("\x1b[?1049h", pty.raw_text())
                        self.assertEqual(daemon.abort_commands(), [])


if __name__ == "__main__":
    unittest.main()
