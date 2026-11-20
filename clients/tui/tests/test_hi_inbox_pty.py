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
                self.assertIn("● Idle First", screen)
                self.assertIn("bash", screen)

                # Initial selection is first attention-needing session (Idle First, Tier 1 above Running Build Tier 2)
                self.assertIn("> ├─ ● Idle First", screen)

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
                pty.wait_for_output("> └─ ● Idle Second")

                pty.send_bytes(b"\t")
                pty.wait_for_output("> ├─ ● Idle First")

                # Press Down/Up arrows as well as j/k (Idle First is above Running Build due to triage tier)
                pty.send_bytes(b"\x1b[B")  # Down -> Running Build
                pty.wait_for_output("> └─ ")
                pty.send_bytes(b"\x1b[A")  # Up -> Idle First
                pty.wait_for_output("> ├─ ● Idle First")

                # j navigates down to Running Build (j/k visit all sessions)
                pty.send_text("j")
                pty.wait_for_output("> └─ ")
                screen_after_j = pty.screen_text()
                self.assertTrue(
                    any(
                        line.startswith("> └─ ") and "Running Build" in line
                        for line in screen_after_j.splitlines()
                    ),
                    f"expected cursor on Running Build; screen=\n{screen_after_j}",
                )

                # Live catalog update: Running Build finishes -> becomes attention-needing (●)
                daemon.update_session_attention("s-run", attention="idle")
                pty.wait_for_output("● Running Build")

                # Press j to select Idle First (Running Build created_at=100 is now above Idle First created_at=200), then Enter to attach
                pty.send_text("j")
                pty.wait_for_output("> └─ ● Idle First")
                pty.send_enter()
                pty.wait_for_output("Hello from Idle First")

                # Ctrl-D on empty editor returns to inbox (entered_from_inbox == true)
                # Looking at Idle First does NOT clear its ● attention dot!
                pty.send_ctrl("d")
                pty.wait_for_output("Inbox · j/k move")
                pty.wait_for_output("> └─ ● Idle First")

                # Re-open Idle Second, then jump back via Alt+I
                pty.send_text("j")
                pty.send_text("j")
                pty.wait_for_output("> └─ ● Idle Second")
                pty.send_enter()
                pty.wait_for_output("Hello from Idle Second")

                pty.send_bytes(b"\x1bi")  # Alt+I
                pty.wait_for_output("Inbox · j/k move")
                pty.wait_for_output("> └─ ● Idle Second")

                # Re-open Idle First, then jump back via /inbox
                pty.send_text("k")
                pty.send_text("k")
                pty.wait_for_output("> └─ ● Idle First")
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

    def test_inbox_triage_stop_archive_and_all_filter_pty(self) -> None:
        with self._setup_multi_session_daemon() as daemon:
            with PtySession(
                [self.hi_bin, "inbox"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=28,
                cols=140,
            ) as pty:
                daemon.wait_for_catalog_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("> ├─ ● Idle First")

                # 1. Press Space on Idle First -> toggles needs_attention to false, renders ○ at bottom of group
                pty.send_text(" ")
                pty.wait_for_output("> └─ ○ Idle First")
                self.assertEqual(
                    daemon.triage_requests[-1],
                    {"session_id": "s-idle-1", "needs_attention": False},
                )

                # Tab now skips Idle First (needs_attention=false) and cycles Broken Job -> Idle Second -> Broken Job
                pty.send_bytes(b"\t")
                pty.wait_for_output("> ├─ ! Broken Job")
                pty.send_bytes(b"\t")
                pty.wait_for_output("> └─ ● Idle Second")
                pty.send_bytes(b"\t")
                pty.wait_for_output("> ├─ ! Broken Job")

                # 2. Navigate up to Running Build and press `s` to stop it -> transitions to ● Running Build idle
                pty.send_text("k")  # -> Idle First (○)
                pty.send_text("k")  # -> Running Build (spinner)
                pty.send_text("s")
                pty.wait_for_output("Stopped s-run")
                pty.wait_for_output("● Running Build")
                self.assertEqual(len(daemon.stop_requests), 1)
                self.assertEqual(daemon.stop_requests[0]["session_id"], "s-run")

                # 3. Press `x` to archive Running Build -> disappears from Inbox view
                pty.send_text("x")
                pty.wait_for_output("Archived s-run")
                self.assertEqual(daemon.archive_requests[-1]["session_id"], "s-run")
                self.assertTrue(daemon.archive_requests[-1]["archived"])

                # 4. Press `a` to toggle All view -> reveals archived Running Build with · indicator
                pty.send_text("a")
                pty.wait_for_output("Inbox [All]")
                pty.wait_for_output("· Running Build")

                pty.send_text("q")
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())

    def test_missing_cwd_session_blocks_submit_and_cwd_command_forks_into_valid_dir(self) -> None:
        missing_dir = os.path.join(self.workdir, "deleted-workspace")
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="s-ok") as daemon:
            daemon.add_session(
                "s-missing",
                cwd=missing_dir,
                title="Missing Dir Session",
                attention="idle",
                cwd_exists=False,
                created_at=100,
                entries=[
                    {
                        "id": "1",
                        "conversation_id": "1",
                        "seq": 1,
                        "kind": "assistant",
                        "data": {"content": [{"type": "text", "text": "Transcript before deletion"}]},
                        "created_at": 100,
                    }
                ],
            )
            with PtySession(
                [self.hi_bin, "inbox"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=28,
                cols=110,
            ) as pty:
                daemon.wait_for_catalog_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Missing Dir Session")
                pty.wait_for_output("[missing cwd]")

                # Select Missing Dir Session and open it
                pty.send_bytes(b"\t")
                pty.wait_for_output("> └─ ● Missing Dir Session")
                pty.send_enter()
                pty.wait_for_output("Transcript before deletion")
                pty.wait_for_output("use /cwd")

                # Attempting to send a prompt is refused with /cwd hint and retains draft
                pty.send_text("continue work")
                pty.send_enter()
                pty.wait_for_output("Working directory no longer exists")
                self.assertEqual(daemon.recorded_commands, [])

                # Clear retained draft and run /cwd <valid_dir> to fork into self.other_dir
                pty.send_ctrl("u")
                pty.send_text(f"/cwd {self.other_dir}")
                pty.send_enter()
                pty.wait_for_output("fork-")
                pty.wait_for_output("Transcript before deletion")
                self.assertEqual(len(daemon.fork_requests), 1)
                self.assertEqual(daemon.fork_requests[0]["source_session_id"], "s-missing")
                self.assertEqual(daemon.fork_requests[0]["cwd"], self.other_dir)

                # Now submitting a prompt in the forked session succeeds!
                pty.wait_for_output("Ready")
                pty.send_text("hello forked")
                pty.send_enter()
                pty.wait_for_output("Forked reply: hello forked")

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())

    def test_opening_archived_session_shows_archived_status_and_resumes_on_prompt(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="s-active") as daemon:
            daemon.add_session(
                "s-archived",
                cwd=self.workdir,
                title="Shelved Feature",
                attention="idle",
                archived=True,
                loaded=False,
                created_at=200,
                entries=[
                    {
                        "id": "1",
                        "conversation_id": "1",
                        "seq": 1,
                        "kind": "assistant",
                        "data": {"content": [{"type": "text", "text": "Shelved transcript body"}]},
                        "created_at": 200,
                    }
                ],
            )
            with PtySession(
                [self.hi_bin, "inbox"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=28,
                cols=120,
            ) as pty:
                daemon.wait_for_catalog_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Demo Session")

                # Switch to All view, move to Shelved Feature, and press Enter to inspect cold
                pty.send_text("a")
                pty.wait_for_output("· Shelved Feature")
                pty.send_text("j")
                pty.wait_for_output("> └─ · Shelved Feature")
                pty.send_enter()

                pty.wait_for_output("Shelved transcript body")
                pty.wait_for_output("archived")
                pty.wait_for_output("Archived (unloaded)")

                # /resume picker also shows [archived], not [idle]
                pty.send_text("/resume")
                pty.send_enter()
                pty.wait_for_output("Shelved Feature [archived]")
                pty.send_ctrl("c")
                time.sleep(0.05)

                # Submitting a prompt resumes and unarchives the session
                pty.send_text("resume work")
                pty.send_enter()
                pty.wait_for_output("Forked reply: resume work")
                self.assertFalse(daemon._extra_sessions["s-archived"]["archived"])

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())


if __name__ == "__main__":
    unittest.main()
