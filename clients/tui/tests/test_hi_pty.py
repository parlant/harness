"""Unix PTY acceptance suite for `hi -s demo` against disposable FakeDaemon.

Run against the integrated `hi` binary with:
    HI_PTY_REQUIRE_BIN=1 HI_BIN=/path/to/hi python3 -m unittest clients/tui/tests/test_hi_pty.py -v
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, "..", "..", ".."))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from fake_daemon import FakeDaemon, extract_content_text  # noqa: E402
from pty_harness import PtySession, find_hi_binary  # noqa: E402


def _require_hi_binary(test_case: unittest.TestCase) -> str:
    hi_bin = find_hi_binary(REPO_ROOT)
    if hi_bin:
        return hi_bin
    msg = (
        "hi binary not found (checked HI_BIN, CARGO_TARGET_DIR, target/{debug,release}/hi). "
        "Wire `hi` in clients/tui and set HI_BIN=/path/to/hi."
    )
    if os.environ.get("HI_PTY_REQUIRE_BIN") == "1":
        test_case.fail(msg)
    test_case.skipTest(msg)
    raise AssertionError("unreachable")


def _assert_balanced_terminal_modes(test_case: unittest.TestCase, raw_output: str) -> None:
    """If hi enables private terminal modes, verify matching disable sequences on exit."""
    pairs = [
        ("\x1b[?1049h", "\x1b[?1049l", "alt-screen"),
        ("\x1b[?2004h", "\x1b[?2004l", "bracketed-paste"),
        ("\x1b[?1000h", "\x1b[?1000l", "mouse-click"),
        ("\x1b[?1002h", "\x1b[?1002l", "mouse-drag"),
        ("\x1b[?1003h", "\x1b[?1003l", "mouse-any"),
        ("\x1b[?1006h", "\x1b[?1006l", "mouse-sgr"),
    ]
    for enable_seq, disable_seq, label in pairs:
        if enable_seq in raw_output:
            test_case.assertGreater(
                raw_output.rfind(disable_seq),
                raw_output.rfind(enable_seq),
                f"expected {label} disable sequence {disable_seq!r} after {enable_seq!r}",
            )

    if "\x1b[?25l" in raw_output:
        test_case.assertGreater(
            raw_output.rfind("\x1b[?25h"),
            raw_output.rfind("\x1b[?25l"),
            "expected cursor-show \\x1b[?25h after hiding cursor",
        )


class HiPtyAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.hi_bin = _require_hi_binary(self)
        self.workdir = tempfile.mkdtemp(prefix="hi-pty-cwd-", dir="/tmp")

    def tearDown(self) -> None:
        shutil.rmtree(self.workdir, ignore_errors=True)

    def test_raw_mode_and_restore_on_quit(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                self.assertTrue(pty.is_raw_mode(), "hi should run in raw terminal mode")

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0, f"/quit failed; output={pty.clean_text()!r}")
                self.assertTrue(pty.is_cooked_mode(), "cooked mode (ECHO|ICANON) must be restored")
                _assert_balanced_terminal_modes(self, pty.raw_text())
                self.assertEqual(daemon.abort_commands(), [])

    def test_shell_prefix_never_falls_through_to_model_input(self) -> None:
        for mode in ("fullscreen", "regular"):
            with self.subTest(mode=mode), FakeDaemon(cwd=self.workdir) as daemon:
                with PtySession([self.hi_bin, "--tui-mode", mode, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                    daemon.wait_for_sse_connect()
                    pty.wait_for_raw_mode()
                    pty.wait_for_output("Ready")

                    pty.send_text("!!private-marker")
                    pty.send_enter()
                    cmd1 = daemon.wait_for_command(
                        lambda c: c["command"] == "user_shell"
                        and c["args"].get("command") == "private-marker"
                    )
                    self.assertEqual(cmd1["version"], 1)
                    self.assertEqual(cmd1["conversation_id"], 1)
                    self.assertEqual(
                        cmd1["args"],
                        {
                            "command": "private-marker",
                            "include_in_context": False,
                            "expected_seq": 1,
                        },
                    )
                    daemon.wait_for_turn_idle()
                    pty.wait_for_output("out:private-marker")

                    pty.send_text("!ctx-cmd")
                    pty.send_alt_enter()
                    cmd2 = daemon.wait_for_command(
                        lambda c: c["command"] == "user_shell"
                        and c["args"].get("command") == "ctx-cmd"
                    )
                    self.assertEqual(
                        cmd2["args"],
                        {
                            "command": "ctx-cmd",
                            "include_in_context": True,
                            "expected_seq": 3,
                        },
                    )
                    daemon.wait_for_turn_idle()
                    pty.wait_for_output("out:ctx-cmd")

                    # Empty shell prefix never submits to model
                    pty.send_text("!")
                    pty.send_enter()
                    pty.wait_for_output("Enter a shell command")
                    pty.send_ctrl("c")
                    pty.send_ctrl("d")
                    self.assertEqual(pty.wait(), 0)
                    submit_cmds = [c for c in daemon.recorded_commands if c["command"] == "submit"]
                    self.assertEqual(submit_cmds, [])

    def test_raw_mode_restore_on_ctrl_d_when_empty(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_ctrl("d")
                self.assertEqual(pty.wait(), 0, f"Ctrl-D exit failed; output={pty.clean_text()!r}")
                self.assertTrue(pty.is_cooked_mode(), "cooked mode must be restored after Ctrl-D")
                _assert_balanced_terminal_modes(self, pty.raw_text())
                self.assertEqual(daemon.abort_commands(), [])

    def test_raw_mode_restore_on_double_ctrl_c(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_ctrl("c")
                time.sleep(0.05)
                self.assertIsNone(
                    pty.proc.poll(),
                    f"first Ctrl-C on empty buffer exited immediately (rc={pty.proc.poll()}); expected double Ctrl-C",
                )
                pty.send_ctrl("c")
                self.assertEqual(pty.wait(), 0, f"double Ctrl-C failed; output={pty.clean_text()!r}")
                self.assertTrue(pty.is_cooked_mode(), "cooked mode must be restored after Ctrl-C")
                _assert_balanced_terminal_modes(self, pty.raw_text())
                self.assertEqual(daemon.abort_commands(), [])

    def test_edit_during_active_stream_preserves_draft_and_cursor_edits(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["StreamChunk1 ", "StreamChunk2 "])
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_text("start stream")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=2)
                pty.wait_for_output("StreamChunk2")

                # Edit draft mid-stream: backspace + left-arrow insertion.
                pty.send_text("hello worldd")
                pty.send_backspace(1)
                pty.send_left(5)
                pty.send_text("brave ")

                daemon.emit_ephemeral_chunk("StreamChunk3 ")
                pty.wait_for_output("StreamChunk3")

                gate.set()
                daemon.wait_for_turn_idle()

                pty.send_enter()
                second = daemon.wait_for_command(
                    lambda c: c["command"] == "submit"
                    and extract_content_text(c["args"].get("content")) != "start stream"
                )
                self.assertEqual(
                    extract_content_text(second["args"].get("content")),
                    "hello brave world",
                )

                daemon.wait_for_turn_idle()
                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())

    def test_enter_submits_steer_during_active_stream(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["Working A ", "Working B "])
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_text("initial task")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1)
                pty.wait_for_output("Working A")

                pty.send_text("steer direction")
                pty.send_enter()

                steer_cmd = daemon.wait_for_command(
                    lambda c: c["command"] == "submit"
                    and extract_content_text(c["args"].get("content")) == "steer direction"
                )
                self.assertEqual(steer_cmd["args"].get("type"), "input")
                self.assertEqual(steer_cmd["args"].get("when_busy"), "steer")
                self.assertEqual(steer_cmd["args"].get("when_idle"), "start")

                gate.set()
                daemon.wait_for_turn_idle()
                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())

    def test_alt_enter_submits_follow_up_during_active_stream(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["Busy A ", "Busy B "])
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_text("first turn")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1)
                pty.wait_for_output("Busy A")

                pty.send_text("queued follow up")
                pty.send_alt_enter()

                followup_cmd = daemon.wait_for_command(
                    lambda c: c["command"] == "submit"
                    and extract_content_text(c["args"].get("content")) == "queued follow up"
                )
                self.assertEqual(followup_cmd["args"].get("type"), "input")
                self.assertEqual(followup_cmd["args"].get("when_busy"), "follow_up")

                gate.set()
                daemon.wait_for_turn_idle()
                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())

    def test_detach_via_quit_during_stream_does_not_abort_and_reattach_sees_completion(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["DetachPart1 ", "DetachPart2 "])
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_text("long running prompt")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1)
                pty.wait_for_output("DetachPart1")

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())
                _assert_balanced_terminal_modes(self, pty.raw_text())

            self.assertEqual(daemon.abort_commands(), [])
            gate.set()
            daemon.wait_for_turn_idle()

            assistant_texts = [
                extract_content_text(e["data"].get("content"))
                for e in daemon.conversation_entries()
                if e.get("kind") == "assistant"
            ]
            self.assertIn("DetachPart1 DetachPart2 ", assistant_texts)

            # Re-attach shows the durable completed assistant message from snapshot.
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty2:
                daemon.wait_for_sse_connect(min_count=2)
                pty2.wait_for_raw_mode()
                pty2.wait_for_output("DetachPart1 DetachPart2")
                pty2.send_ctrl("d")
                self.assertEqual(pty2.wait(), 0)
                self.assertTrue(pty2.is_cooked_mode())

    def test_detach_via_pty_hangup_during_stream_does_not_abort(self) -> None:
        with FakeDaemon(transport="uds", cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["HangupChunk "])
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_text("disconnect test")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1)

                pty.close_master_hangup()
                pty.wait()

            self.assertEqual(daemon.abort_commands(), [])
            gate.set()
            daemon.wait_for_turn_idle()

    def test_resize_during_stream_and_loopback_http_transport(self) -> None:
        with FakeDaemon(transport="tcp", cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["TcpStreamA ", "TcpStreamB "])
            with PtySession(
                [self.hi_bin, "-s", "demo"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=24,
                cols=80,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_text("tcp prompt")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1)

                pty.resize(30, 100)
                time.sleep(0.05)
                pty.resize(16, 50)
                time.sleep(0.05)

                pty.send_text("tcp followup")
                pty.send_alt_enter()
                cmd = daemon.wait_for_command(
                    lambda c: c["command"] == "submit"
                    and extract_content_text(c["args"].get("content")) == "tcp followup"
                )
                self.assertEqual(cmd["args"].get("when_busy"), "follow_up")

                gate.set()
                daemon.wait_for_turn_idle()
                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)
                self.assertTrue(pty.is_cooked_mode())
                self.assertEqual(daemon.abort_commands(), [])


if __name__ == "__main__":
    unittest.main()
