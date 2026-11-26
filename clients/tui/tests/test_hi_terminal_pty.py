"""Terminal-specific Unix PTY suite for `hi` in fullscreen and regular modes.

Covers selection/completion, inline model/help pickers, isolated tmux/SSH
environments, and composed Unicode handling against a disposable FakeDaemon.
No user terminal settings are modified and no remote hosts are contacted.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

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
        "Set HI_BIN=/path/to/hi."
    )
    if os.environ.get("HI_PTY_REQUIRE_BIN") == "1":
        test_case.fail(msg)
    test_case.skipTest(msg)
    raise AssertionError("unreachable")


class TerminalFakeDaemon(FakeDaemon):
    """Disposable FakeDaemon extended with multi-model catalog and configure support."""

    def __init__(self, *, cwd: str, session_id: str = "demo", transport: str = "uds") -> None:
        super().__init__(transport=transport, cwd=cwd, session_id=session_id)
        self.models: list[dict[str, Any]] = [
            {"id": "fake/test-model", "name": "Test Model", "provider": "fake"},
            {"id": "openai/gpt-5.2-codex", "name": "GPT-5.2 Codex", "provider": "openai"},
            {"id": "anthropic/claude-sonnet", "name": "Claude Sonnet", "provider": "anthropic"},
        ]
        self.force_configure_conflict = False
        self.login_state: str | None = None
        self.login_requests: list[tuple[str, dict[str, Any]]] = []
        self.key_requests: list[tuple[str, dict[str, Any]]] = []

    def seed_entry(self, kind: str, text: str) -> None:
        with self._lock:
            entry = self._next_entry_locked(kind, {"content": [{"type": "text", "text": text}]})
            self._entries.append(entry)
            self._seq += 1

    def _execute_command_locked(self, raw: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        if raw.get("command") == "configure":
            req_id = raw.get("request_id")
            cid_raw = raw.get("conversation_id")
            args = raw.get("args") or {}
            if raw.get("version") != 1 or not isinstance(req_id, str) or cid_raw != 1:
                return 422, {"error": "invalid command envelope"}

            self.recorded_commands.append(
                {
                    "version": 1,
                    "request_id": req_id,
                    "conversation_id": cid_raw,
                    "command": "configure",
                    "args": args,
                }
            )
            expected_seq = args.get("expected_seq")
            if self.force_configure_conflict or (
                expected_seq is not None and expected_seq != self._seq
            ):
                self._cond.notify_all()
                return 409, {"error": f"expected_seq mismatch (current {self._seq})"}

            agent = dict(self._docs.get("agent") or {})
            if isinstance(args.get("model"), str):
                agent["model"] = args["model"]
                self.model_id = args["model"]
            if isinstance(args.get("thinking"), str):
                agent["thinking"] = args["thinking"]
            self._docs["agent"] = agent
            seq = self._commit_locked(doc_ops={"agent": [["replace", dict(agent)]]})
            return 200, {"version": 1, "request_id": req_id, "seq": seq, "status": "configured"}

        return super()._execute_command_locked(raw)

    def _make_handler_class(self) -> Any:
        base_cls = super()._make_handler_class()
        daemon = self

        class TerminalHandler(base_cls):
            def do_GET(self) -> None:
                parsed = urlsplit(self.path)
                if parsed.path == "/api/v1/provider-logins" and daemon.login_state is not None:
                    if not self._check_auth_and_host():
                        return
                    self._send_json(200, {"providers": [{"id": "openai_codex",
                        "interaction": "device_code_v1", "sources": [{"id": "work", "state": "not_signed_in"}]}]})
                    return
                if parsed.path == "/api/v1/fs/files":
                    if not self._check_auth_and_host():
                        return
                    params = parse_qs(parsed.query)
                    cwd = os.path.realpath(params["cwd"][0])
                    # This fake only browses the disposable fixture tree.
                    root = os.path.realpath(daemon.cwd)
                    if os.path.commonpath((cwd, root)) != root or not os.path.isdir(cwd):
                        self._send_json(404, {"error": "missing fixture directory"})
                        return
                    query = params.get("query", [""])[0].lower()
                    with os.scandir(cwd) as listing:
                        entries = [
                            {"path": e.name, "type": "dir" if e.is_dir() else "file"}
                            for e in listing if query in e.name.lower()
                        ]
                    self._send_json(200, {"env_id": params["env_id"][0], "cwd": cwd, "entries": entries})
                    return
                if parsed.path == "/api/v1/models":
                    if not self._check_auth_and_host():
                        return
                    self._send_json(200, {"models": daemon.models})
                    return
                super().do_GET()

            def do_POST(self) -> None:
                path = urlsplit(self.path).path
                if path == "/api/v1/provider-keys/set":
                    if not self._check_auth_and_host():
                        return
                    params = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    daemon.key_requests.append((path, params))
                    self._send_json(200, {"active": params["source"], "provider": params["provider"]})
                    return
                if path == "/api/v1/provider-accounts/activate":
                    if not self._check_auth_and_host():
                        return
                    params = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    with daemon._lock:
                        daemon.login_requests.append(("activate", params))
                    self._send_json(200, {"active": params["source"]})
                    return
                if daemon.login_state is None or not path.startswith("/api/v1/provider-logins/"):
                    return super().do_POST()
                if not self._check_auth_and_host():
                    return
                action = path.rsplit("/", 1)[1]
                params = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                with daemon._lock:
                    daemon.login_requests.append((action, params))
                    if action == "cancel":
                        daemon.login_state = "cancelled"
                    state = daemon.login_state
                payload = {"source": "work", "state": state, "operation": "r" * 43}
                if state == "pending":
                    payload.update(verification_url="https://auth.openai.com/codex/device",
                                   user_code="ABCD-1234", expires_in_ms=30_000, poll_after_ms=500)
                self._send_json(200, payload)

        return TerminalHandler


def _assert_mode_sequences(test_case: unittest.TestCase, raw_output: str, mode: str) -> None:
    if mode == "fullscreen":
        for seq in ("\x1b[?1049h", "\x1b[?2004h", "\x1b[?1000h", "\x1b[?1006h"):
            test_case.assertIn(seq, raw_output, f"fullscreen mode should enable {seq!r}")
        for en, dis in (
            ("\x1b[?1049h", "\x1b[?1049l"),
            ("\x1b[?2004h", "\x1b[?2004l"),
            ("\x1b[?1000h", "\x1b[?1000l"),
            ("\x1b[?1006h", "\x1b[?1006l"),
        ):
            test_case.assertGreater(raw_output.rfind(dis), raw_output.rfind(en))
    else:
        test_case.assertNotIn("\x1b[?1049h", raw_output, "regular mode must not enter alt-screen")
        for mouse_seq in ("\x1b[?1000h", "\x1b[?1002h", "\x1b[?1003h", "\x1b[?1006h"):
            test_case.assertNotIn(
                mouse_seq,
                raw_output,
                "regular mode must leave mouse/selection to the native terminal",
            )
        test_case.assertIn("\x1b[?2004h", raw_output, "regular mode enables bracketed paste")
        test_case.assertGreater(raw_output.rfind("\x1b[?2004l"), raw_output.rfind("\x1b[?2004h"))


def _tmux_available() -> bool:
    return shutil.which("tmux") is not None


class HiTerminalBothModesTests(unittest.TestCase):
    MODES = ("fullscreen", "regular")

    def setUp(self) -> None:
        self.hi_bin = _require_hi_binary(self)
        self.workdir = tempfile.mkdtemp(prefix="hi-term-cwd-", dir="/tmp")
        with open(os.path.join(self.workdir, "readme.txt"), "w", encoding="utf-8") as f:
            f.write("fixture café 👋\n")
        os.makedirs(os.path.join(self.workdir, "sub"), exist_ok=True)
        with open(os.path.join(self.workdir, "sub", "nested.rs"), "w", encoding="utf-8") as f:
            f.write("pub fn ok() -> bool { true }\n")

    def tearDown(self) -> None:
        shutil.rmtree(self.workdir, ignore_errors=True)

    def test_device_login_uses_only_owner_api_and_never_submits_code(self) -> None:
        for mode, outcome in (("fullscreen", "complete"), ("regular", "cancelled")):
            with self.subTest(mode=mode), TerminalFakeDaemon(cwd=self.workdir) as daemon:
                daemon.login_state = "pending"
                with PtySession([self.hi_bin, "-s", "demo", "--tui-mode", mode],
                                env=daemon.env(), cwd=self.workdir, rows=24, cols=100) as pty:
                    daemon.wait_for_sse_connect()
                    pty.wait_for_raw_mode()
                    pty.send_text("/login openai-codex")
                    pty.send_enter()
                    pty.wait_for_output("work  [not signed in]")
                    pty.send_enter()
                    pty.wait_for_output(["https://auth.openai.com/codex/device", "ABCD-1234"])
                    if outcome == "complete":
                        with daemon._lock:
                            daemon.login_state = "complete"
                        screen = pty.wait_for_output("Signed in. Choose a Codex model")
                    else:
                        pty.send_bytes(b"\x1b")
                        screen = pty.wait_for_output("Login cancelled.")
                    self.assertNotIn("ABCD-1234", screen)
                    pty.send_enter()
                    self.assertEqual(daemon.recorded_commands, [])
                    action, start = daemon.login_requests[0]
                    self.assertEqual(action, "start")
                    self.assertEqual(start["provider"], "openai_codex")
                    self.assertEqual(start["source"], "work")
                    self.assertTrue(start["request_id"])
                    self.assertIn(("status" if outcome == "complete" else "cancel",
                                   {"operation": "r" * 43}), daemon.login_requests)

    def test_cli_account_and_login_do_not_open_a_session(self) -> None:
        with TerminalFakeDaemon(cwd=self.workdir) as daemon:
            daemon.login_state = "complete"
            env = daemon.env()
            for args, expected in [
                (["account", "list"], "work"),
                (["login", "openai_codex", "work"], "Signed in to work"),
                (["daemon", "status"], "Running:"),
            ]:
                output = subprocess.run([self.hi_bin, *args], env=env, cwd=self.workdir,
                                        capture_output=True, text=True, timeout=6, check=True)
                self.assertIn(expected, output.stdout)
            self.assertEqual(daemon.login_requests[0][0], "start")
            self.assertEqual(daemon.recorded_commands, [])
            self.assertEqual(daemon.sse_connect_count, 0)

    def test_daemon_status_distinguishes_stopped_daemon_and_bad_auth(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hi-down-", dir="/tmp") as data:
            env = dict(os.environ, H_DATA_DIR=data)
            env.pop("H_DAEMON_URL", None)
            def status():
                return subprocess.run([self.hi_bin, "daemon", "status"], env=env,
                                      capture_output=True, text=True, timeout=6)
            result = status()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Daemon is not running", result.stderr)

            # A closed listener leaves a real socket inode behind, as H can on exit.
            path = Path(data) / "api.sock"
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(path))
                listener.listen(1)
            token = Path(data, "auth.token")
            token.write_text("unused-test-token\n")
            token.chmod(0o600)
            result = status()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Daemon is not running at unix://", result.stderr)
            self.assertNotIn("Connection refused", result.stderr)
            self.assertTrue(path.is_socket())

        with TerminalFakeDaemon(cwd=self.workdir) as daemon:
            env = daemon.env()
            Path(env["H_DATA_DIR"], "auth.token").write_text("wrong-test-token\n")
            result = status()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("HTTP 401", result.stderr)
            self.assertNotIn("not running", result.stderr)

    def test_restart_ui_resubscribes_without_resubmitting_or_aborting(self) -> None:
        with TerminalFakeDaemon(cwd=self.workdir) as daemon:
            gate = daemon.arm_gated_stream(chunks=["still working"])
            with PtySession([self.hi_bin, "-s", "demo", "--conversation", "1"], env=daemon.env(),
                            cwd=self.workdir, rows=24, cols=100) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_output("Ready")
                pty.send_text("Build")
                pty.send_enter()
                daemon.wait_for_stream_active()
                pty.send_text("/restart-ui " + self.hi_bin)
                pty.send_enter()
                daemon.wait_for_sse_connect(min_count=2)
                pty.wait_for_output("still working")
                self.assertEqual([cmd["command"] for cmd in daemon.recorded_commands], ["submit"])
                gate.set()

    def test_api_key_entry_is_masked_and_does_not_submit_a_prompt(self) -> None:
        secret = "fixture-write-only-key"
        with TerminalFakeDaemon(cwd=self.workdir) as daemon:
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir,
                            rows=24, cols=100) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_output("Ready")
                pty.send_text("/key set openai work")
                pty.send_enter()
                pty.wait_for_output("Save openai API key as work")
                pty.send_bytes(b"\x1b[200~" + secret.encode() + b"\x1b[201~")
                screen = pty.wait_for_output("*" * len(secret))
                self.assertNotIn(secret, screen)
                pty.send_enter()
                screen = pty.wait_for_output("Saved openai key work")
                self.assertNotIn(secret, screen)
                self.assertEqual(daemon.recorded_commands, [])
                self.assertEqual(daemon.key_requests, [("/api/v1/provider-keys/set", {
                    "provider": "openai", "source": "work", "api_key": secret})])

    def test_account_switch_is_an_owner_action_not_a_conversation_command(self) -> None:
        with TerminalFakeDaemon(cwd=self.workdir) as daemon:
            daemon.login_state = "complete"
            with PtySession([self.hi_bin, "-s", "demo"], env=daemon.env(), cwd=self.workdir,
                            rows=24, cols=100) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.send_text("/account")
                pty.send_enter()
                pty.wait_for_output("Select stock Codex account")
                pty.send_enter()
                pty.wait_for_output("Stock Codex account: work")
                self.assertEqual(daemon.login_requests, [("activate", {"source": "work"})])
                self.assertEqual(daemon.recorded_commands, [])

    def test_selection_and_completion_in_both_modes(self) -> None:
        for mode in self.MODES:
            with self.subTest(mode=mode):
                with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
                    daemon.arm_auto_stream(chunks=["Assistant selection café 👋"])
                    cmd = [self.hi_bin, "-s", "demo", "--tui-mode", mode]
                    with PtySession(cmd, env=daemon.env(), cwd=self.workdir, rows=24, cols=80) as pty:
                        daemon.wait_for_sse_connect()
                        pty.wait_for_raw_mode()
                        pty.wait_for_output("Ready")

                        # 1. Complete in the draft; Esc restores the prefix without aborting.
                        pty.send_text("/")
                        pty.send_bytes(b"\t")
                        screen = pty.wait_for_output("Commands · Tab to cycle (1/")
                        self.assertIn("/resume", screen.splitlines())
                        pty.send_bytes(b"\x1b")
                        pty.wait_for_output("\n/\n")
                        pty.send_text("he")
                        pty.send_bytes(b"\t")
                        screen = pty.wait_for_output("Commands · Tab to cycle (1/1)")
                        self.assertIn("/help", screen.splitlines())
                        pty.send_bytes(b"\x1b")
                        pty.wait_for_output("\n/he\n")
                        pty.send_backspace(1)
                        pty.send_bytes(b"\t")
                        screen = pty.wait_for_output("Commands · Tab to cycle (1/3)")
                        self.assertIn("/harness", screen.splitlines())
                        self.assertIn("/help", screen)
                        self.assertIn("/hotkeys", screen)
                        pty.send_bytes(b"\t")
                        screen = pty.wait_for_output("Commands · Tab to cycle (2/3)")
                        self.assertIn("/help", screen.splitlines())
                        pty.send_bytes(b"\t")
                        screen = pty.wait_for_output("Commands · Tab to cycle (3/3)")
                        self.assertIn("/hotkeys", screen.splitlines())
                        pty.send_bytes(b"\x1b")
                        pty.wait_for_output("\n/h\n")
                        self.assertEqual(daemon.abort_commands(), [])

                        # Clear the prefix and open the separate client-local attachment picker.
                        pty.send_ctrl("u")
                        pty.send_text("/attach su")
                        pty.send_bytes(b"\t")
                        pty.wait_for_output("client files · Search:")
                        pty.wait_for_output("sub/")
                        pty.send_enter()  # drill into sub/
                        pty.wait_for_output("nested.rs")
                        pty.send_enter()  # attach sub/nested.rs
                        pty.wait_for_output("Attached client-local sub/nested.rs")

                        # Submit prompt with attached file
                        pty.send_text("check attached")
                        pty.send_enter()
                        sub_cmd = daemon.wait_for_command(lambda c: c["command"] == "submit")
                        payload = extract_content_text(sub_cmd["args"]["content"])
                        self.assertIn("check attached", payload)
                        self.assertIn("sub/nested.rs", payload)
                        self.assertIn("pub fn ok()", payload)
                        daemon.wait_for_turn_idle()
                        pty.wait_for_output("Assistant selection")

                        # 2. Explicit /copy emits OSC 52 preserving UTF-8 assistant reply
                        pty.send_text("/copy")
                        pty.send_enter()
                        pty.wait_for_output("Clipboard requested")
                        osc52 = re.findall(r"\x1b\]52;c;([A-Za-z0-9+/=]+)\x07", pty.raw_text())
                        self.assertTrue(osc52, f"[{mode}] expected OSC 52 clipboard sequence")
                        self.assertEqual(
                            base64.b64decode(osc52[-1]).decode("utf-8"),
                            "Assistant selection café 👋",
                        )

                        pty.send_text("/quit")
                        pty.send_enter()
                        self.assertEqual(pty.wait(), 0)
                        self.assertTrue(pty.is_cooked_mode())
                        _assert_mode_sequences(self, pty.raw_text(), mode)

    def test_path_completion_in_both_modes(self) -> None:
        for mode in self.MODES:
            with self.subTest(mode=mode):
                with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
                    cmd = [self.hi_bin, "-s", "demo", "--tui-mode", mode]
                    # The client CWD intentionally differs from the session CWD.
                    with tempfile.TemporaryDirectory(dir="/tmp") as client_cwd:
                        with PtySession(cmd, env=daemon.env(), cwd=client_cwd, rows=24, cols=80) as pty:
                            daemon.wait_for_sse_connect()
                            pty.wait_for_raw_mode()
                            pty.wait_for_output("Ready")
                            pty.send_text("check su")
                            pty.send_bytes(b"\t")
                            pty.wait_for_output("\ncheck sub/\n")
                            pty.send_bytes(b"\t")
                            pty.wait_for_output("\ncheck sub/nested.rs\n")
                            self.assertEqual(daemon.recorded_commands, [])
                            pty.send_enter()
                            submitted = daemon.wait_for_command(lambda c: c["command"] == "submit")
                            self.assertEqual(extract_content_text(submitted["args"]["content"]), "check sub/nested.rs")
                            pty.send_text("/quit")
                            pty.send_enter()
                            self.assertEqual(pty.wait(), 0)

    def test_inline_model_help_hotkeys_and_conflict_in_both_modes(self) -> None:
        for mode in self.MODES:
            with self.subTest(mode=mode):
                with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
                    daemon.seed_entry("user", "abcd让EFGH transcript stays visible")
                    cmd = [self.hi_bin, "-s", "demo", "--tui-mode", mode]
                    with PtySession(cmd, env=daemon.env(), cwd=self.workdir, rows=24, cols=80) as pty:
                        daemon.wait_for_sse_connect()
                        pty.wait_for_raw_mode()
                        pty.wait_for_output(["abcd让EFGH", "abcd让 EFGH"])

                        # 1. /help opens inline command picker; pick /model into editor
                        pty.send_text("/help")
                        pty.send_enter()
                        pty.wait_for_output("commands · Search:")
                        pty.send_text("model")
                        pty.wait_for_output("/model")
                        pty.send_enter()
                        pty.wait_for_output("Enter to run command")

                        # 2. Run /model -> inline models picker over CJK transcript + resize
                        pty.send_enter()
                        screen = pty.wait_for_output("models · Search:")
                        self.assertTrue(
                            "abcd让EFGH" in screen or "abcd让 EFGH" in screen,
                            f"CJK transcript line missing or corrupted: {screen!r}",
                        )
                        pty.send_text("openai/codex52")
                        pty.wait_for_output("openai/gpt-5.2-codex")
                        pty.resize(20, 60)
                        time.sleep(0.05)
                        pty.send_enter()

                        cfg = daemon.wait_for_command(
                            lambda c: c["command"] == "configure"
                            and c["args"].get("model") == "openai/gpt-5.2-codex"
                        )
                        self.assertEqual(cfg["args"].get("expected_seq"), 2)
                        pty.wait_for_output("configured · seq 3")

                        # 3. Ctrl+L inline model picker with 409 conflict surfaces conflict cleanly
                        daemon.force_configure_conflict = True
                        pty.send_ctrl("l")
                        pty.wait_for_output("models · Search:")
                        pty.send_text("claude")
                        pty.wait_for_output("anthropic/claude-sonnet")
                        pty.send_enter()
                        pty.wait_for_output("conflict:")

                        # 4. /thinking inline picker + /hotkeys inline shortcuts list
                        daemon.force_configure_conflict = False
                        pty.send_text("/thinking")
                        pty.send_enter()
                        pty.wait_for_output("thinking · Search:")
                        pty.send_text("high")
                        pty.send_enter()
                        daemon.wait_for_command(
                            lambda c: c["command"] == "configure"
                            and c["args"].get("thinking") == "high"
                        )

                        pty.send_text("/hotkeys")
                        pty.send_enter()
                        hk = pty.wait_for_output("shortcuts · Search:")
                        self.assertIn("ctrl+l", hk)
                        pty.send_bytes(b"\x1b")
                        time.sleep(0.05)

                        pty.send_text("/quit")
                        pty.send_enter()
                        self.assertEqual(pty.wait(), 0)
                        self.assertTrue(pty.is_cooked_mode())

    def test_context_footer_aligns_and_updates_branch_and_latest_turn_in_both_modes(self) -> None:
        layout = [
            "{{ cwd_short }}{% if git_branch %} ({{ git_branch }}){% endif %}",
            "{% set meter %}{% if context_window %}{{ '%.0f' | format(context_percent) if context_percent is not none else '—' }}%/{{ context_window | compact }}{% else %}—{% endif %}{% endset %}{{ align(meter, model ~ ':' ~ thinking) }}",
        ]
        project = Path(self.workdir) / "sub"
        git = Path(self.workdir) / ".git"
        git.mkdir()
        head = git / "HEAD"
        model = "openai_codex:gpt-6.2-sol"
        right = f"{model}:high"
        for mode in self.MODES:
            with self.subTest(mode=mode):
                head.write_text("ref: refs/heads/main\n")
                with TerminalFakeDaemon(cwd=str(project)) as daemon:
                    daemon._docs["agent"] = {"model": model, "thinking": "high"}
                    daemon.models = [{"id": model, "provider": "openai_codex", "context_window": 500_000}]
                    (Path(daemon.data_dir) / "hi.json").write_text(json.dumps({"status_lines": layout}))
                    cmd = [self.hi_bin, "-s", "demo", "--tui-mode", mode]
                    with PtySession(cmd, env={**daemon.env(), "HOME": self.workdir}, cwd=self.workdir, rows=16, cols=100) as pty:
                        daemon.wait_for_sse_connect()
                        pty.wait_for_output("~/sub (main)")
                        pty.wait_for_output("0%/500k".ljust(100 - len(right)) + right)

                        with daemon._lock:
                            entry = daemon._next_entry_locked("assistant", {
                                "content": "Fixture answer", "usage": {"input_tokens": 124_000, "output_tokens": 1_000},
                            })
                            daemon._docs["usage"]["total_tokens"] = 900_000
                            daemon._commit_locked(appended_entries=[entry], doc_ops={"usage": [["replace", daemon._docs["usage"]]]})

                        left = "25%/500k"
                        pty.wait_for_output(left.ljust(100 - len(right)) + right)
                        pty.resize(16, 72)
                        pty.wait_for_output(left.ljust(72 - len(right)) + right)
                        head.unlink()
                        deadline = time.monotonic() + 5
                        while "~/sub (main)" in pty.screen_text() and time.monotonic() < deadline:
                            time.sleep(0.03)
                        self.assertIn("~/sub", pty.screen_text())
                        self.assertNotIn("~/sub (main)", pty.screen_text())

    def test_status_templates_reload_atomically_and_follow_live_model_in_both_modes(self) -> None:
        for mode in self.MODES:
            with self.subTest(mode=mode):
                with TerminalFakeDaemon(cwd=self.workdir) as daemon:
                    daemon.seed_entry("user", "status fixture transcript")
                    user_file = Path(daemon.data_dir) / "hi.json"
                    keys_file = Path(daemon.data_dir) / "hi-keybindings.json"
                    user_file.write_text(json.dumps({"status_lines_append": ["Extra: {{ session_title }}"]}))
                    cmd = [self.hi_bin, "-s", "demo", "--tui-mode", mode]
                    with PtySession(cmd, env=daemon.env(), cwd=self.workdir, rows=16, cols=110) as pty:
                        daemon.wait_for_sse_connect()
                        pty.wait_for_output("Extra: Demo Session")
                        pty.wait_for_output("Ready · /help")
                        user_file.write_text(json.dumps({"status_lines": [
                            "{{ provider }} / {{ model_name }} ({{ thinking }}) · {{ activity }}",
                            "{% if provider == 'openai' %}Provider branch: {{ session_status }}{% endif %}",
                            "{{ note }}",
                        ]}))
                        keys_file.write_text(json.dumps({"model": "ctrl+b"}))
                        pty.send_text("/reload")
                        pty.send_enter()
                        pty.wait_for_output("Hi configuration reloaded")
                        screen = pty.wait_for_output("fake / test-model (medium) · idle")
                        self.assertNotIn("Extra:", screen)
                        self.assertNotIn("Provider branch:", screen)
                        self.assertIn("status fixture transcript", screen)

                        pty.send_ctrl("b")
                        pty.wait_for_output("models · Search:")
                        pty.send_text("codex")
                        pty.wait_for_output("openai/gpt-5.2-codex")
                        pty.send_enter()
                        screen = pty.wait_for_output("Provider branch: ok")
                        self.assertIn("openai / gpt-5.2-codex (medium) · idle", screen)

                        # A bad keymap must roll back the footer too.
                        user_file.write_text(json.dumps({"status_lines": ["must not apply"]}))
                        keys_file.write_text(json.dumps({"model": "ctrl+c"}))
                        pty.send_text("/reload")
                        pty.send_enter()
                        pty.wait_for_output("reload failed (config unchanged)")
                        pty.send_ctrl("c")  # cancel picker without an ambiguous ESC prefix
                        pty.wait_for_output("Reload failed:")
                        pty.send_ctrl("b")
                        screen = pty.wait_for_output("models · Search:")
                        self.assertIn("Provider branch: ok", screen)
                        self.assertNotIn("must not apply", screen)
                        pty.send_ctrl("c")  # cancel picker without an ambiguous ESC prefix

                        # An invalid template must also leave the existing key binding in force.
                        user_file.write_text(json.dumps({"status_lines": ["{{ not_a_field }}"]}))
                        keys_file.unlink()
                        pty.send_text("/reload")
                        pty.send_enter()
                        pty.wait_for_output("reload failed (config unchanged)")
                        pty.send_ctrl("c")  # cancel picker without an ambiguous ESC prefix
                        pty.send_ctrl("b")
                        screen = pty.wait_for_output("models · Search:")
                        self.assertIn("Provider branch: ok", screen)
                        pty.send_ctrl("c")  # cancel picker without an ambiguous ESC prefix

                        # Check that an empty footer is allowed and can be restored immediately.
                        user_file.write_text('{"status_lines": []}')
                        pty.send_text("/reload")
                        pty.send_enter()
                        pty.send_text("draft with no footer")
                        screen = pty.wait_for_output("draft with no footer")
                        self.assertNotIn("Provider branch:", screen)
                        self.assertIn("status fixture transcript", screen)
                        pty.send_ctrl("u")
                        user_file.write_text('{"status_lines": ["restored · {{ note }}"]}')
                        pty.send_text("/reload")
                        pty.send_enter()
                        screen = pty.wait_for_output("restored · Hi configuration reloaded")
                        self.assertNotIn("Provider branch:", screen)
                        self.assertIn("status fixture transcript", screen)
                        pty.send_text("/quit")
                        pty.send_enter()
                        self.assertEqual(pty.wait(), 0)
                        self.assertEqual(len(daemon.recorded_commands), 1)  # configure only

    def test_composed_unicode_cursor_editing_paste_and_resize_in_both_modes(self) -> None:
        for mode in self.MODES:
            with self.subTest(mode=mode):
                with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
                    daemon.arm_auto_stream(
                        chunks=["Stream: e\u0301 ", "\U0001f468\u200d\U0001f4bb ", "\U0001f1e8\U0001f1f3 \U0001f1e8 abcd\u8ba9EFGH"]
                    )
                    cmd = [self.hi_bin, "-s", "demo", "--tui-mode", mode]
                    with PtySession(cmd, env=daemon.env(), cwd=self.workdir, rows=24, cols=80) as pty:
                        daemon.wait_for_sse_connect()
                        pty.wait_for_raw_mode()
                        pty.wait_for_output("Ready")

                        # 1. Type NFD accent + CJK + ZWJ emoji + flag + skin-tone (display width 1+4+2+2+2 = 11 -> col 12)
                        before_len = len(pty.raw_text())
                        pty.send_text(
                            "e\u0301\u4f60\u597d\U0001f468\u200d\U0001f4bb\U0001f1e8\U0001f1f3\U0001f44d\U0001f3fb"
                        )
                        time.sleep(0.15)
                        tail_raw = pty.raw_text()[before_len:]
                        if mode == "fullscreen":
                            cups = re.findall(r"\x1b\[(\d+);(\d+)H", tail_raw)
                            self.assertTrue(
                                any(col == "12" for _, col in cups),
                                f"[{mode}] expected hardware cursor col 12 for width 11; cups={cups[-6:]}",
                            )
                        else:
                            chas = re.findall(r"\x1b\[(\d+)G", tail_raw)
                            self.assertTrue(
                                "12" in chas,
                                f"[{mode}] expected hardware cursor CHA col 12 for width 11; chas={chas[-6:]}",
                            )

                        # 2. Grapheme-atomic Left across 👍🏻 + 🇨🇳, Backspace deletes whole 👨‍💻 cluster
                        pty.send_left(2)
                        pty.send_backspace(1)
                        pty.send_enter()
                        sub1 = daemon.wait_for_command(lambda c: c["command"] == "submit")
                        self.assertEqual(
                            extract_content_text(sub1["args"]["content"]),
                            "e\u0301\u4f60\u597d\U0001f1e8\U0001f1f3\U0001f44d\U0001f3fb",
                        )
                        daemon.wait_for_turn_idle()
                        pty.wait_for_output("abcd")

                        # 3. Bracketed paste with composed Unicode + newline + /quit must stay draft text
                        paste = (
                            b"\x1b[200~cafe\xcc\x81 \xf0\x9f\x8f\xb3\xef\xb8\x8f\xe2\x80\x8d\xf0\x9f\x8c\x88 "
                            b"\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\n/quit\x1b[201~"
                        )
                        pty.send_bytes(paste)
                        time.sleep(0.1)
                        self.assertIsNone(pty.proc.poll(), "pasted /quit must not exit hi")
                        pty.send_enter()
                        sub2 = daemon.wait_for_command(
                            lambda c: c["command"] == "submit" and c["request_id"] != sub1["request_id"]
                        )
                        self.assertEqual(
                            extract_content_text(sub2["args"]["content"]),
                            "cafe\u0301 \U0001f3f3\ufe0f\u200d\U0001f308 \U0001f1fa\U0001f1f8\n/quit",
                        )
                        daemon.wait_for_turn_idle()

                        # 4. Narrow resize with CJK/flag/ZWJ transcript does not crash and stays responsive
                        pty.resize(12, 18)
                        time.sleep(0.05)
                        pty.resize(24, 80)
                        time.sleep(0.05)

                        pty.send_text("/quit")
                        pty.send_enter()
                        self.assertEqual(pty.wait(), 0)
                        self.assertTrue(pty.is_cooked_mode())


class HiTerminalSshAndTmuxTests(unittest.TestCase):
    def setUp(self) -> None:
        self.hi_bin = _require_hi_binary(self)
        self.workdir = tempfile.mkdtemp(prefix="hi-term-ssh-", dir="/tmp")

    def tearDown(self) -> None:
        shutil.rmtree(self.workdir, ignore_errors=True)

    def test_tmux_extended_keys_always_csi_u_and_ssh_env_in_both_modes(self) -> None:
        if not _tmux_available():
            self.skipTest("tmux not installed")

        tmux_conf = os.path.join(self.workdir, "tmux-csiu.conf")
        with open(tmux_conf, "w", encoding="utf-8") as f:
            f.write(
                "set -g extended-keys always\n"
                "set -g extended-keys-format csi-u\n"
                "set -sg escape-time 10\n"
            )

        for mode in ("fullscreen", "regular"):
            with self.subTest(mode=mode):
                tmux_sock = os.path.join(self.workdir, f"tmux-{mode}.sock")
                with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
                    gate = daemon.arm_gated_stream(chunks=["TmuxStream1 "])
                    env = daemon.env()
                    env["SSH_CONNECTION"] = "127.0.0.1 54321 127.0.0.1 22"
                    env["SSH_TTY"] = "/dev/ttys099"
                    tmux_cmd = [
                        "tmux",
                        "-S",
                        tmux_sock,
                        "-f",
                        tmux_conf,
                        "new-session",
                        "-x",
                        "80",
                        "-y",
                        "24",
                        self.hi_bin,
                        "-s",
                        "demo",
                        "--tui-mode",
                        mode,
                    ]
                    try:
                        with PtySession(tmux_cmd, env=env, cwd=self.workdir, rows=24, cols=80) as pty:
                            daemon.wait_for_sse_connect()
                            pty.wait_for_output("Ready")

                            # Shift+Enter via CSI-u inserts newline instead of submitting
                            pty.send_text("tmux_l1")
                            pty.send_bytes(b"\x1b[13;2u")
                            pty.send_text("tmux_l2")
                            pty.send_enter()
                            sub1 = daemon.wait_for_command(lambda c: c["command"] == "submit")
                            self.assertEqual(
                                extract_content_text(sub1["args"]["content"]),
                                "tmux_l1\ntmux_l2",
                            )
                            daemon.wait_for_stream_active(min_ephemerals=1)

                            # Alt+Enter via CSI-u and ESC+CR both queue follow_up
                            pty.send_text("tmux_fu_csiu")
                            pty.send_bytes(b"\x1b[13;3u")
                            fu1 = daemon.wait_for_command(
                                lambda c: c["command"] == "submit"
                                and extract_content_text(c["args"]["content"]) == "tmux_fu_csiu"
                            )
                            self.assertEqual(fu1["args"].get("when_busy"), "follow_up")

                            pty.send_text("tmux_fu_escr")
                            pty.send_alt_enter()
                            fu2 = daemon.wait_for_command(
                                lambda c: c["command"] == "submit"
                                and extract_content_text(c["args"]["content"]) == "tmux_fu_escr"
                            )
                            self.assertEqual(fu2["args"].get("when_busy"), "follow_up")

                            gate.set()
                            daemon.wait_for_turn_idle()
                            pty.send_text("/quit")
                            pty.send_enter()
                            self.assertEqual(pty.wait(), 0)
                            self.assertTrue(pty.is_cooked_mode())
                    finally:
                        subprocess.run(
                            ["tmux", "-S", tmux_sock, "kill-server"],
                            capture_output=True,
                            check=False,
                        )

    def test_tmux_extended_keys_on_fallback_ctrl_j_and_slash_follow_up(self) -> None:
        if not _tmux_available():
            self.skipTest("tmux not installed")

        # Matches pi's recommended `extended-keys on` without `always`:
        # because crossterm only sends Kitty `\x1b[>1u` (not xterm modifyOtherKeys),
        # tmux without outer Kitty negotiation strips Shift+Enter, so Ctrl+J and
        # `/follow-up` serve as reliable fallbacks.
        tmux_conf = os.path.join(self.workdir, "tmux-on.conf")
        with open(tmux_conf, "w", encoding="utf-8") as f:
            f.write(
                "set -g extended-keys on\n"
                "set -g extended-keys-format csi-u\n"
                "set -sg escape-time 10\n"
            )
        tmux_sock = os.path.join(self.workdir, "tmux-on.sock")
        with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["TmuxOn1 "])
            env = daemon.env()
            env["SSH_CONNECTION"] = "127.0.0.1 54321 127.0.0.1 22"
            tmux_cmd = [
                "tmux",
                "-S",
                tmux_sock,
                "-f",
                tmux_conf,
                "new-session",
                "-x",
                "80",
                "-y",
                "24",
                self.hi_bin,
                "-s",
                "demo",
            ]
            try:
                with PtySession(tmux_cmd, env=env, cwd=self.workdir, rows=24, cols=80) as pty:
                    daemon.wait_for_sse_connect()
                    pty.wait_for_output("Ready")

                    pty.send_text("ctrlj_a")
                    pty.send_ctrl("j")
                    pty.send_text("ctrlj_b")
                    pty.send_enter()
                    sub = daemon.wait_for_command(lambda c: c["command"] == "submit")
                    self.assertEqual(
                        extract_content_text(sub["args"]["content"]),
                        "ctrlj_a\nctrlj_b",
                    )
                    daemon.wait_for_stream_active(min_ephemerals=1)

                    pty.send_text("/follow-up explicit fallback")
                    pty.send_enter()
                    fu = daemon.wait_for_command(
                        lambda c: c["command"] == "submit"
                        and extract_content_text(c["args"]["content"]) == "explicit fallback"
                    )
                    self.assertEqual(fu["args"].get("when_busy"), "follow_up")

                    gate.set()
                    daemon.wait_for_turn_idle()
                    pty.send_text("/quit")
                    pty.send_enter()
                    self.assertEqual(pty.wait(), 0)
            finally:
                subprocess.run(["tmux", "-S", tmux_sock, "kill-server"], capture_output=True, check=False)

    def test_ssh_split_escape_behavior_and_hangup_in_both_modes(self) -> None:
        # 1. Split ESC + CR (50ms packet gap under SSH_CONNECTION): documents that Crossterm
        #    dispatches lone ESC immediately (aborting active turn) and CR as Enter (steer),
        #    unlike pi's SSH-aware 100ms escape timeout. `/follow-up` remains safe.
        with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["SshChunk "])
            env = daemon.env()
            env["SSH_CONNECTION"] = "127.0.0.1 55555 127.0.0.1 22"
            env["SSH_TTY"] = "/dev/ttys001"
            with PtySession([self.hi_bin, "-s", "demo"], env=env, cwd=self.workdir) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()

                pty.send_text("start")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1)

                pty.send_text("split_test")
                pty.send_bytes(b"\x1b")
                time.sleep(0.05)
                pty.send_bytes(b"\r")
                sub = daemon.wait_for_command(
                    lambda c: c["command"] == "submit"
                    and extract_content_text(c["args"]["content"]) == "split_test"
                )
                self.assertEqual(len(daemon.abort_commands()), 1)
                self.assertEqual(sub["args"].get("when_busy"), "steer")

                gate.set()
                daemon.wait_for_turn_idle()
                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

        # 2. Lost SSH PTY hangup in regular mode never sends abort
        with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
            gate = daemon.arm_gated_stream(chunks=["RegularHangup "])
            env = daemon.env()
            env["SSH_CONNECTION"] = "127.0.0.1 55555 127.0.0.1 22"
            with PtySession(
                [self.hi_bin, "-s", "demo", "--tui-mode", "regular"],
                env=env,
                cwd=self.workdir,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.send_text("drop regular")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1)
                pty.close_master_hangup()
                pty.wait()
            self.assertEqual(daemon.abort_commands(), [])
            gate.set()
            daemon.wait_for_turn_idle()

    def test_term_dumb_never_enters_raw_mode(self) -> None:
        with TerminalFakeDaemon(cwd=self.workdir, session_id="demo") as daemon:
            daemon.arm_auto_stream(chunks=["Plain dumb output"])
            env = daemon.env()
            env["TERM"] = "dumb"
            with PtySession([self.hi_bin, "-s", "demo", "-p", "hi"], env=env, cwd=self.workdir) as pty:
                self.assertEqual(pty.wait(timeout=5.0), 0)
                self.assertTrue(pty.is_cooked_mode())
                self.assertEqual(pty.clean_text().strip(), "Plain dumb output")
                self.assertNotIn("\x1b[?1049h", pty.raw_text())


if __name__ == "__main__":
    unittest.main()
