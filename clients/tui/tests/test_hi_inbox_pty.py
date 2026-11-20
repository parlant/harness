"""Unix PTY end-to-end tests for `hi inbox` and `/inbox` multi-session browser."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, "..", "..", ".."))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from fake_daemon import FakeDaemon  # noqa: E402
from pty_harness import PtySession, find_hi_binary  # noqa: E402
from test_hi_pty import _assert_balanced_terminal_modes, _require_hi_binary  # noqa: E402


class HiInboxPtyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.hi_bin = _require_hi_binary(self)
        self.workdir = tempfile.mkdtemp(prefix="hi-inbox-cwd-", dir="/tmp")
        self.other_dir = tempfile.mkdtemp(prefix="hi-inbox-other-", dir="/tmp")

    def tearDown(self) -> None:
        shutil.rmtree(self.workdir, ignore_errors=True)
        shutil.rmtree(self.other_dir, ignore_errors=True)

    def _setup_multi_session_daemon(self) -> FakeDaemon:
        daemon = FakeDaemon(transport="uds", cwd=self.workdir, session_id="s-run")
        daemon.add_session(
            "s-run",
            cwd=self.workdir,
            title="Running Build",
            attention="running",
            activity_kind="tool",
            activity_label="bash",
            created_at=100,
        )
        daemon.add_session(
            "s-idle-1",
            cwd=self.workdir,
            title="Idle First",
            attention="idle",
            created_at=200,
            entries=[
                {
                    "id": "1",
                    "conversation_id": "1",
                    "seq": 1,
                    "kind": "assistant",
                    "data": {"content": [{"type": "text", "text": "Hello from Idle First"}]},
                    "created_at": 200,
                }
            ],
        )
        daemon.add_session(
            "s-err",
            cwd=self.other_dir,
            title="Broken Job",
            attention="error",
            activity_label="model_error",
            created_at=300,
            entries=[
                {
                    "id": "1",
                    "conversation_id": "1",
                    "seq": 1,
                    "kind": "assistant",
                    "data": {"content": [{"type": "text", "text": "Hello from Broken Job"}]},
                    "created_at": 300,
                }
            ],
        )
        daemon.add_session(
            "s-idle-2",
            cwd=self.other_dir,
            title="Idle Second",
            attention="idle",
            created_at=400,
            entries=[
                {
                    "id": "1",
                    "conversation_id": "1",
                    "seq": 1,
                    "kind": "assistant",
                    "data": {"content": [{"type": "text", "text": "Hello from Idle Second"}]},
                    "created_at": 400,
                }
            ],
        )
        return daemon

    def test_hi_inbox_non_tty_returns_clear_error(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            proc = subprocess.run(
                [self.hi_bin, "inbox"],
                cwd=self.workdir,
                env=daemon.env(),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("hi inbox requires an interactive TTY", proc.stderr)
            self.assertEqual(daemon.created_sessions, [])

    def test_inbox_tree_indicators_spinner_and_navigation_tab_skips_running(self) -> None:
        with self._setup_multi_session_daemon() as daemon:
            with PtySession(
                [self.hi_bin, "inbox"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=28,
                cols=100,
            ) as pty:
                daemon.wait_for_catalog_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Running Build")
                pty.wait_for_output("Idle First")
                pty.wait_for_output("Broken Job")
                pty.wait_for_output("Idle Second")

                # No session was created on startup
                self.assertEqual(daemon.created_sessions, [])

                screen = pty.screen_text()
                self.assertIn(self.workdir, screen)
                self.assertIn(self.other_dir, screen)
                self.assertIn("├─ ", screen)
                self.assertIn("└─ ", screen)
                self.assertIn("! Broken Job", screen)
                self.assertIn("paused: model_error", screen)
                self.assertIn("○ Idle First", screen)
                self.assertIn("bash", screen)

                # Initial selection is first attention-needing session (Idle First)
                self.assertIn("> └─ ○ Idle First", screen)

                # Verify running spinner animates across frames
                spinner_chars = set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
                seen_frames: set[str] = set()
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline and len(seen_frames) < 2:
                    for line in pty.screen_text().splitlines():
                        if "Running Build" in line:
                            for ch in line:
                                if ch in spinner_chars:
                                    seen_frames.add(ch)
                    time.sleep(0.06)
                self.assertGreaterEqual(
                    len(seen_frames),
                    2,
                    f"expected spinner animation across >=2 frames; saw={seen_frames!r}",
                )

                # Tab cycles attention-needing sessions only: Idle First -> Broken Job -> Idle Second -> Idle First
                pty.send_bytes(b"\t")
                pty.wait_for_output("> ├─ ! Broken Job")

                pty.send_bytes(b"\t")
                pty.wait_for_output("> └─ ○ Idle Second")

                pty.send_bytes(b"\t")
                pty.wait_for_output("> └─ ○ Idle First")

                # Press Up/Down arrows as well as j/k
                pty.send_bytes(b"\x1b[A")  # Up -> Running Build
                pty.wait_for_output("> ├─ ")
                pty.send_bytes(b"\x1b[B")  # Down -> Idle First
                pty.wait_for_output("> └─ ○ Idle First")

                # k navigates up to Running Build (j/k visit all sessions)
                pty.send_text("k")
                pty.wait_for_output("> ├─ ")
                screen_after_k = pty.screen_text()
                self.assertTrue(
                    any(
                        line.startswith("> ├─ ") and "Running Build" in line
                        for line in screen_after_k.splitlines()
                    ),
                    f"expected cursor on Running Build; screen=\n{screen_after_k}",
                )

                # Live catalog update: Running Build finishes -> becomes newly idle (●)
                daemon.update_session_attention("s-run", attention="idle")
                pty.wait_for_output("● Running Build")

                # Press j to select Idle First, then Enter to attach to it
                pty.send_text("j")
                pty.wait_for_output("> └─ ○ Idle First")
                pty.send_enter()
                pty.wait_for_output("Hello from Idle First")

                # Ctrl-D on empty editor returns to inbox (entered_from_inbox == true)
                pty.send_ctrl("d")
                pty.wait_for_output("Inbox · j/k move")
                pty.wait_for_output("> └─ ○ Idle First")

                # Re-open Idle Second, then jump back via Alt+I
                pty.send_text("j")
                pty.send_text("j")
                pty.wait_for_output("> └─ ○ Idle Second")
                pty.send_enter()
                pty.wait_for_output("Hello from Idle Second")

                pty.send_bytes(b"\x1bi")  # Alt+I
                pty.wait_for_output("Inbox · j/k move")
                pty.wait_for_output("> └─ ○ Idle Second")

                # Re-open Idle First, then jump back via /inbox
                pty.send_text("k")
                pty.send_text("k")
                pty.wait_for_output("> └─ ○ Idle First")
                pty.send_enter()
                pty.wait_for_output("Hello from Idle First")
                pty.send_text("/inbox")
                pty.send_enter()
                pty.wait_for_output("Inbox · j/k move")

                # Ctrl-D in inbox exits hi cleanly, restoring cooked mode with zero aborts
                pty.send_ctrl("d")
                self.assertEqual(
                    pty.wait(), 0, f"Ctrl-D exit from inbox failed; out={pty.clean_text()!r}"
                )
                self.assertTrue(pty.is_cooked_mode(), "cooked mode must be restored")
                _assert_balanced_terminal_modes(self, pty.raw_text())
                self.assertEqual(daemon.abort_commands(), [])

    def test_direct_session_ctrl_d_still_exits_immediately_without_inbox(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            with PtySession(
                [self.hi_bin, "-s", "demo"],
                env=daemon.env(),
                cwd=self.workdir,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Ready")

                pty.send_ctrl("d")
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())
                self.assertEqual(daemon.abort_commands(), [])

    def test_inbox_n_creates_session_in_selected_workspace_and_regular_mode_works(self) -> None:
        with self._setup_multi_session_daemon() as daemon:
            with PtySession(
                [self.hi_bin, "inbox", "--tui-mode", "regular"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=28,
                cols=100,
            ) as pty:
                daemon.wait_for_catalog_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Broken Job")

                # Move to Broken Job in self.other_dir and press `n`
                pty.send_bytes(b"\t")
                pty.wait_for_output("> ├─ ! Broken Job")
                pty.send_text("n")
                pty.wait_for_output("Ready")

                self.assertEqual(len(daemon.created_sessions), 1)
                self.assertEqual(daemon.created_sessions[0]["cwd"], self.other_dir)

                # Ctrl-D returns to inbox, then `q` exits cleanly
                pty.send_ctrl("d")
                pty.wait_for_output("Inbox · j/k move")
                pty.send_text("q")
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())
                self.assertEqual(daemon.abort_commands(), [])


if __name__ == "__main__":
    unittest.main()
