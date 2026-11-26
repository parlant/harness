"""Unix PTY integration tests for R6b-2 cutover features of `hi`."""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, "..", "..", ".."))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from fake_daemon import FakeDaemon, extract_content_text  # noqa: E402
from pty_harness import PtySession, find_hi_binary  # noqa: E402

TINY_PNG_B64 = base64.b64encode(
    base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    )
).decode("ascii")


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


class CutoverFakeDaemon(FakeDaemon):
    """FakeDaemon extended with R6 endpoints (logout, key remove, harnesses, extension-status, approvals, budget, task abort)."""

    def __init__(self, *, cwd: str, session_id: str = "demo", transport: str = "uds") -> None:
        super().__init__(transport=transport, cwd=cwd, session_id=session_id)
        self.provider_logins: list[dict[str, Any]] = [
            {
                "id": "openai_codex",
                "interaction": "device_code_v1",
                "sources": [
                    {"id": "work", "state": "signed_in", "active": True},
                    {"id": "personal", "state": "signed_in", "active": False},
                ],
            }
        ]
        self.provider_keys: list[dict[str, Any]] = [
            {"provider": "openai", "sources": ["work", "backup"], "active": "work"},
            {"provider": "anthropic", "sources": ["main"], "active": "main"},
        ]
        self.harnesses: list[dict[str, Any]] = [
            {
                "id": "coding",
                "name": "Coding",
                "description": "Default coding harness",
                "aliases": ["pi"],
            },
            {
                "id": "review",
                "name": "Code Review",
                "description": "Read-only review harness",
                "aliases": [],
            },
        ]
        self.account_remove_requests: list[dict[str, Any]] = []
        self.key_remove_requests: list[dict[str, Any]] = []
        self.extension_status_requests: list[tuple[str, str]] = []
        self.extension_eligible_sources: int = 3
        self.extension_max_age_ms: int = 5000

    def seed_assistant_image(self, *, text: str = "Here is the preview:", b64: str = TINY_PNG_B64) -> None:
        with self._lock:
            entry = self._next_entry_locked(
                "assistant",
                {
                    "content": [
                        {"type": "text", "text": text},
                        {"type": "image", "mime_type": "image/png", "data": b64},
                    ],
                    "finish_reason": "stop",
                },
            )
            self._entries.append(entry)
            self._seq += 1

    def push_live_approval(self, *, task_id: int = 99, call_id: str = "call_99", tool_name: str = "bash") -> int:
        with self._lock:
            live_doc = dict(self._docs.get("live") or {})
            approvals = dict(live_doc.get("approvals") or {})
            approvals[str(task_id)] = {
                "task_id": str(task_id),
                "call_id": call_id,
                "tool_name": tool_name,
                "arguments": {"command": "echo hi"},
                "cwd": self.cwd,
            }
            live_doc["approvals"] = approvals
            self._docs["live"] = live_doc
            return self._commit_locked(doc_ops={"live": [["replace", live_doc]]})

    def _execute_command_locked(self, raw: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        command = raw.get("command")
        req_id = raw.get("request_id")
        cid_raw = raw.get("conversation_id")
        args = raw.get("args") or {}
        if (
            raw.get("version") != 1
            or not isinstance(req_id, str)
            or str(cid_raw) not in self._conversations
        ):
            return 422, {"error": "invalid command envelope"}

        if command == "approve_tool":
            self.recorded_commands.append(
                {
                    "version": 1,
                    "request_id": req_id,
                    "conversation_id": cid_raw,
                    "command": command,
                    "args": args,
                }
            )
            tid = str(args.get("task_id"))
            live_doc = dict(self._docs.get("live") or {})
            approvals = dict(live_doc.get("approvals") or {})
            approvals.pop(tid, None)
            if approvals:
                live_doc["approvals"] = approvals
            else:
                live_doc.pop("approvals", None)
            self._docs["live"] = live_doc
            seq = self._commit_locked(doc_ops={"live": [["replace", live_doc]]})
            self._cond.notify_all()
            return 200, {
                "version": 1,
                "request_id": req_id,
                "seq": seq,
                "status": "approved" if args.get("decision") == "allow" else "denied",
            }

        if command == "configure":
            self.recorded_commands.append(
                {
                    "version": 1,
                    "request_id": req_id,
                    "conversation_id": cid_raw,
                    "command": command,
                    "args": args,
                }
            )
            agent = dict(self._docs.get("agent") or {})
            if "budget" in args:
                agent["budget"] = args["budget"]
            if "approval_policy" in args:
                agent["approval_policy"] = args["approval_policy"]
            self._docs["agent"] = agent
            seq = self._commit_locked(doc_ops={"agent": [["replace", dict(agent)]]})
            self._cond.notify_all()
            return 200, {"version": 1, "request_id": req_id, "seq": seq, "status": "configured"}

        return super()._execute_command_locked(raw)

    def _make_handler_class(self) -> Any:
        base_cls = super()._make_handler_class()
        daemon = self

        class CutoverHandler(base_cls):
            def do_GET(self) -> None:
                parsed = urlsplit(self.path)
                path = parsed.path
                if path == "/api/v1/provider-logins":
                    if not self._check_auth_and_host():
                        return
                    with daemon._lock:
                        self._send_json(200, {"providers": list(daemon.provider_logins)})
                    return
                if path == "/api/v1/provider-keys":
                    if not self._check_auth_and_host():
                        return
                    with daemon._lock:
                        self._send_json(200, {"providers": list(daemon.provider_keys)})
                    return
                if path == "/api/v1/harnesses":
                    if not self._check_auth_and_host():
                        return
                    with daemon._lock:
                        self._send_json(200, {"harnesses": list(daemon.harnesses)})
                    return
                if path.startswith("/api/v1/sessions/") and path.endswith("/extension-status"):
                    if not self._check_auth_and_host():
                        return
                    parts = path.split("/")
                    # ['', 'api', 'v1', 'sessions', '<sid>', 'conversations', '<cid>', 'extension-status']
                    if len(parts) == 8 and parts[5] == "conversations":
                        sid = parts[4]
                        cid = parts[6]
                        with daemon._lock:
                            daemon.extension_status_requests.append((sid, cid))
                            eligible = daemon.extension_eligible_sources
                            max_age_ms = daemon.extension_max_age_ms
                            model = daemon.model_id
                        self._send_json(
                            200,
                            {
                                "version": 1,
                                "session_id": sid,
                                "conversation_id": cid,
                                "model": model,
                                "max_age_ms": max_age_ms,
                                "extensions": {
                                    "account_pool": {"eligible_sources": eligible}
                                },
                            },
                        )
                        return
                super().do_GET()

            def do_POST(self) -> None:
                path = urlsplit(self.path).path
                if path == "/api/v1/provider-accounts/remove":
                    if not self._check_auth_and_host():
                        return
                    length = int(self.headers.get("Content-Length", "0"))
                    body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}
                    source = body.get("source")
                    with daemon._lock:
                        daemon.account_remove_requests.append(body)
                        for p in daemon.provider_logins:
                            if p.get("id") == "openai_codex":
                                p["sources"] = [s for s in p["sources"] if s.get("id") != source]
                    self._send_json(200, {"removed": source})
                    return
                if path == "/api/v1/provider-keys/remove":
                    if not self._check_auth_and_host():
                        return
                    length = int(self.headers.get("Content-Length", "0"))
                    body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}
                    provider = body.get("provider")
                    source = body.get("source")
                    with daemon._lock:
                        daemon.key_remove_requests.append(body)
                        for p in daemon.provider_keys:
                            if p.get("provider") == provider:
                                p["sources"] = [s for s in p["sources"] if s != source]
                                if p.get("active") == source:
                                    p["active"] = p["sources"][0] if p["sources"] else None
                    self._send_json(200, {"removed": source, "provider": provider})
                    return
                if path == "/api/v1/sessions":
                    if not self._check_auth_and_host():
                        return
                    length = int(self.headers.get("Content-Length", "0"))
                    body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}
                    cwd = body.get("cwd") or daemon.cwd
                    env_id = body.get("env_id") or "host"
                    sid = body.get("session_id") or f"sess-harness-{len(daemon.created_sessions) + 1}"
                    title = body.get("title")
                    harness_id = body.get("harness_id") or "coding"
                    wire = daemon.add_session(
                        sid,
                        cwd=cwd,
                        env_id=env_id,
                        title=title,
                        attention="idle",
                    )
                    wire["harness_id"] = harness_id
                    with daemon._lock:
                        daemon._extra_sessions[sid]["harness_id"] = harness_id
                        daemon.created_sessions.append(
                            {"session": wire, "request": body}
                        )
                    self._send_json(200, {"session": wire, "seq": 1})
                    return
                super().do_POST()

        return CutoverHandler


class HiR6CutoverPtyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.hi_bin = _require_hi_binary(self)
        self.workdir = tempfile.mkdtemp(prefix="hi-r6-cwd-", dir="/tmp")

    def tearDown(self) -> None:
        shutil.rmtree(self.workdir, ignore_errors=True)

    def test_cli_logout_and_key_remove(self) -> None:
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            env = daemon.env()

            # `hi logout` with no arg resolves the active Codex account (`work`)
            res_logout_active = subprocess.run(
                [self.hi_bin, "logout"],
                env=env,
                cwd=self.workdir,
                capture_output=True,
                text=True,
                timeout=6,
                check=True,
            )
            self.assertIn("Removed work", res_logout_active.stdout)

            # `hi logout personal` removes explicit alias
            res_logout_explicit = subprocess.run(
                [self.hi_bin, "logout", "personal"],
                env=env,
                cwd=self.workdir,
                capture_output=True,
                text=True,
                timeout=6,
                check=True,
            )
            self.assertIn("Removed personal", res_logout_explicit.stdout)
            self.assertEqual(
                daemon.account_remove_requests,
                [{"source": "work"}, {"source": "personal"}],
            )

            # `hi key remove <provider> <source>` removes stored key
            res_key_rm = subprocess.run(
                [self.hi_bin, "key", "remove", "openai", "backup"],
                env=env,
                cwd=self.workdir,
                capture_output=True,
                text=True,
                timeout=6,
                check=True,
            )
            self.assertIn("Removed openai key: backup", res_key_rm.stdout)
            self.assertEqual(
                daemon.key_remove_requests,
                [{"provider": "openai", "source": "backup"}],
            )
            self.assertEqual(daemon.recorded_commands, [])
            self.assertEqual(daemon.sse_connect_count, 0)

    def test_slash_logout_and_key_remove_pty(self) -> None:
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            with PtySession(
                [self.hi_bin, "-s", "demo"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=24,
                cols=100,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Ready")

                # /logout opens picker and removes selected account
                pty.send_text("/logout")
                pty.send_enter()
                pty.wait_for_output("Log out Codex account")
                pty.send_enter()
                pty.wait_for_output("Removed Codex account: work")

                # /logout personal removes directly
                pty.send_text("/logout personal")
                pty.send_enter()
                pty.wait_for_output("Removed Codex account: personal")

                # /key remove opens picker and removes selected key
                pty.send_text("/key remove")
                pty.send_enter()
                pty.wait_for_output("Remove provider key")
                pty.send_enter()
                pty.wait_for_output("Removed openai key: work")

                # /key remove anthropic main removes directly
                pty.send_text("/key remove anthropic main")
                pty.send_enter()
                pty.wait_for_output("Removed anthropic key: main")

                self.assertEqual(
                    daemon.account_remove_requests,
                    [{"source": "work"}, {"source": "personal"}],
                )
                self.assertEqual(
                    daemon.key_remove_requests,
                    [
                        {"provider": "openai", "source": "work"},
                        {"provider": "anthropic", "source": "main"},
                    ],
                )
                self.assertEqual(daemon.recorded_commands, [])

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

    def test_harness_cli_flag_and_slash_harness_command(self) -> None:
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            # 1. `--harness review` creates a new session with harness_id="review"
            with PtySession(
                [self.hi_bin, "--harness", "review"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=24,
                cols=100,
            ) as pty:
                pty.wait_for_raw_mode()
                pty.wait_for_output("Ready")

                self.assertEqual(len(daemon.created_sessions), 1)
                self.assertEqual(
                    daemon.created_sessions[0]["request"].get("harness_id"),
                    "review",
                )

                first_sid = daemon.created_sessions[0]["session"]["session_id"]

                # 2. `/harness` opens the harnesses menu and selecting `coding` creates a session with harness_id="coding"
                pty.send_text("/harness")
                pty.send_enter()
                screen = pty.wait_for_output("harnesses · Search:")
                self.assertIn("coding (Coding)", screen)
                self.assertIn("* review", screen)
                pty.send_text("coding")
                pty.wait_for_output("coding (Coding)")
                pty.send_enter()
                deadline = time.monotonic() + 5.0
                while len(daemon.created_sessions) < 2 and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertEqual(len(daemon.created_sessions), 2)
                second_sid = daemon.created_sessions[1]["session"]["session_id"]
                self.assertNotEqual(second_sid, first_sid)
                pty.wait_for_output(f"{second_sid}:1")
                self.assertEqual(
                    daemon.created_sessions[1]["request"].get("harness_id"),
                    "coding",
                )

                # 3. `/harness review` directly creates a session with harness_id="review"
                pty.send_text("/harness review")
                pty.send_enter()
                deadline = time.monotonic() + 5.0
                while len(daemon.created_sessions) < 3 and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertEqual(len(daemon.created_sessions), 3)
                third_sid = daemon.created_sessions[2]["session"]["session_id"]
                pty.wait_for_output(f"{third_sid}:1")
                self.assertEqual(
                    daemon.created_sessions[2]["request"].get("harness_id"),
                    "review",
                )

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

    def test_tool_approval_overlay_approve_deny_budget_and_task_abort(self) -> None:
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            with PtySession(
                [self.hi_bin, "-s", "demo"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=24,
                cols=100,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Ready")

                # 1. Push live.approvals entry -> overlay opens automatically; Esc dismisses without denying
                daemon.push_live_approval(task_id=99, call_id="call_99", tool_name="bash")
                pty.wait_for_output("Tool approval · bash (#99)")
                pty.send_bytes(b"\x1b")
                pty.wait_for_output("[approval required · #99]")

                # 2. `/approve` (without arg) approves sole pending task 99
                pty.send_text("/approve")
                pty.send_enter()
                cmd1 = daemon.wait_for_command(lambda c: c["command"] == "approve_tool")
                self.assertEqual(cmd1["args"]["task_id"], 99)
                self.assertEqual(cmd1["args"]["decision"], "allow")
                pty.wait_for_output("approved · seq")

                # 3. Second approval -> `/deny 101 unsafe` denies task 101 with reason
                daemon.push_live_approval(task_id=101, call_id="call_101", tool_name="write")
                pty.wait_for_output("Tool approval · write (#101)")
                pty.send_bytes(b"\x1b")
                pty.wait_for_output("[approval required · #101]")
                pty.send_text("/deny 101 unsafe")
                pty.send_enter()
                cmd2 = daemon.wait_for_command(
                    lambda c: c["command"] == "approve_tool" and c["args"]["task_id"] == 101
                )
                self.assertEqual(cmd2["args"]["decision"], "deny")
                self.assertEqual(cmd2["args"]["reason"], "unsafe")
                pty.wait_for_output("denied · seq")

                # 4. `/budget turns=4 cost=1.25 elapsed=15s` and `/budget off`
                pty.send_text("/budget turns=4 cost=1.25 elapsed=15s")
                pty.send_enter()
                b1 = daemon.wait_for_command(
                    lambda c: c["command"] == "configure" and c["args"].get("budget") is not None
                )
                self.assertEqual(b1["args"]["budget"]["max_turns"], 4)
                self.assertEqual(b1["args"]["budget"]["max_cost_usd"], 1.25)
                self.assertEqual(b1["args"]["budget"]["max_elapsed_ms"], 15_000)
                pty.wait_for_output("configured · seq")

                pty.send_text("/budget off")
                pty.send_enter()
                b2 = daemon.wait_for_command(
                    lambda c: c["command"] == "configure"
                    and "budget" in c["args"]
                    and c["args"]["budget"] is None
                )
                self.assertIsNone(b2["args"]["budget"])

                # 5. Task-scoped `/abort 101 cancel tool`
                pty.send_text("/abort 101 cancel tool")
                pty.send_enter()
                ab = daemon.wait_for_command(lambda c: c["command"] == "abort")
                self.assertEqual(ab["args"]["task_id"], 101)
                self.assertEqual(ab["args"]["reason"], "cancel tool")

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

    def test_extension_status_in_hi_json_and_reload(self) -> None:
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            hi_json = Path(daemon.data_dir) / "hi.json"
            hi_json.write_text(
                json.dumps(
                    {
                        "extension_status": True,
                        "status_lines": [
                            "Pool: {% if extensions.account_pool is defined and extensions.account_pool.eligible_sources is defined %}{{ extensions.account_pool.eligible_sources }}{% else %}none{% endif %} · {{ note }}"
                        ],
                    }
                )
            )

            with PtySession(
                [self.hi_bin, "-s", "demo"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=20,
                cols=100,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Pool: 3 ·")
                self.assertGreaterEqual(len(daemon.extension_status_requests), 1)

                # Update extension value on daemon & toggle extension_status off -> /reload disables it
                daemon.extension_eligible_sources = 5
                hi_json.write_text(
                    json.dumps(
                        {
                            "extension_status": False,
                            "status_lines": [
                                "Pool: {% if extensions.account_pool is defined and extensions.account_pool.eligible_sources is defined %}{{ extensions.account_pool.eligible_sources }}{% else %}off{% endif %} · {{ note }}"
                            ],
                        }
                    )
                )
                pty.send_text("/reload")
                pty.send_enter()
                pty.wait_for_output("Pool: off · Hi configuration reloaded")

                # Re-enable extension_status -> /reload polls fresh value 5
                hi_json.write_text(
                    json.dumps(
                        {
                            "extension_status": True,
                            "status_lines": [
                                "Pool: {% if extensions.account_pool is defined and extensions.account_pool.eligible_sources is defined %}{{ extensions.account_pool.eligible_sources }}{% else %}off{% endif %} · {{ note }}"
                            ],
                        }
                    )
                )
                pty.send_text("/reload")
                pty.send_enter()
                pty.wait_for_output("Pool: 5 · Hi configuration reloaded")

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

    def test_custom_json_theme_and_reload_rollback_on_invalid_theme(self) -> None:
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            themes_dir = Path(daemon.data_dir) / "themes"
            themes_dir.mkdir(parents=True, exist_ok=True)
            custom_theme = themes_dir / "custom.json"
            custom_theme.write_text(
                json.dumps(
                    {
                        "base": "dark",
                        "user_header": {"fg": "#12ab34", "bold": True},
                    }
                )
            )
            hi_json = Path(daemon.data_dir) / "hi.json"
            hi_json.write_text(
                json.dumps(
                    {
                        "theme": "custom",
                        "status_lines": ["Theme={{ theme }} · {{ note }}"],
                    }
                )
            )

            with PtySession(
                [self.hi_bin, "-s", "demo"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=20,
                cols=100,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Theme=custom ·")
                # Custom user_header truecolor RGB(0x12, 0xab, 0x34) -> 18;171;52
                daemon.seed_entry("user", "themed user msg") if False else None
                pty.send_text("themed prompt")
                pty.send_enter()
                daemon.wait_for_command(lambda c: c["command"] == "submit")
                daemon.wait_for_turn_idle()
                pty.wait_for_output("themed prompt")
                self.assertIn("38;2;18;171;52", pty.raw_text())

                # Corrupt custom.json + attempt theme/status change -> /reload rolls back cleanly
                custom_theme.write_text('{"unknown_theme_field": 123}')
                hi_json.write_text(
                    json.dumps(
                        {
                            "theme": "custom",
                            "status_lines": ["SHOULD_NOT_APPLY · {{ note }}"],
                        }
                    )
                )
                pty.send_text("/reload")
                pty.send_enter()
                pty.wait_for_output("reload failed (config unchanged)")
                pty.send_ctrl("c")
                screen = pty.wait_for_output("Reload failed:")
                self.assertIn("Theme=custom ·", screen)
                self.assertNotIn("SHOULD_NOT_APPLY", screen)

                # Fix custom.json and reload cleanly
                custom_theme.write_text(json.dumps({"base": "light"}))
                hi_json.write_text(
                    json.dumps(
                        {
                            "theme": "custom",
                            "status_lines": ["Theme={{ theme }} · reloaded · {{ note }}"],
                        }
                    )
                )
                pty.send_text("/reload")
                pty.send_enter()
                pty.wait_for_output("Theme=custom · reloaded · Hi configuration reloaded")

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

    def test_prompt_template_expansion_and_submission(self) -> None:
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            prompts_dir = Path(daemon.data_dir) / "prompts"
            prompts_dir.mkdir(parents=True, exist_ok=True)
            (prompts_dir / "review.md").write_text("# Review\nInspect {{args}} carefully.")

            with PtySession(
                [self.hi_bin, "-s", "demo"],
                env=daemon.env(),
                cwd=self.workdir,
                rows=24,
                cols=100,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("Ready")

                # Tab completion discovers /prompt:review
                pty.send_text("/prompt:")
                pty.send_bytes(b"\t")
                pty.wait_for_output("Commands · Tab to cycle (1/1)")
                pty.send_bytes(b"\x1b")
                pty.wait_for_output("\n/prompt:\n")

                # Execute /prompt:review with args -> expands and submits markdown template
                pty.send_text("review src/main.rs")
                pty.send_enter()
                sub_cmd = daemon.wait_for_command(lambda c: c["command"] == "submit")
                self.assertEqual(
                    extract_content_text(sub_cmd["args"]["content"]),
                    "# Review\nInspect src/main.rs carefully.",
                )
                daemon.wait_for_turn_idle()
                pty.wait_for_output("Inspect src/main.rs carefully.")

                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

    def test_inline_images_regular_kitty_iterm2_vs_fullscreen_text_only(self) -> None:
        # 1. Regular mode with HI_INLINE_IMAGES=kitty emits Kitty graphics sequence
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            daemon.seed_assistant_image(text="kitty preview")
            env = dict(daemon.env(), HI_INLINE_IMAGES="kitty")
            with PtySession(
                [self.hi_bin, "-s", "demo", "--tui-mode", "regular"],
                env=env,
                cwd=self.workdir,
                rows=24,
                cols=100,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("[image: image/png")
                raw = pty.raw_text()
                self.assertIn(f"\x1b_Gf=100,a=T,q=2;{TINY_PNG_B64}\x1b\\", raw)
                self.assertNotIn("\x1b]1337;File=", raw)
                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

        # 2. Regular mode with HI_INLINE_IMAGES=iterm2 emits OSC 1337 sequence
        with CutoverFakeDaemon(cwd=self.workdir) as daemon:
            daemon.seed_assistant_image(text="iterm2 preview")
            env = dict(daemon.env(), HI_INLINE_IMAGES="iterm2")
            with PtySession(
                [self.hi_bin, "-s", "demo", "--tui-mode", "regular"],
                env=env,
                cwd=self.workdir,
                rows=24,
                cols=100,
            ) as pty:
                daemon.wait_for_sse_connect()
                pty.wait_for_raw_mode()
                pty.wait_for_output("[image: image/png")
                raw = pty.raw_text()
                decoded_len = len(base64.b64decode(TINY_PNG_B64))
                self.assertIn(
                    f"\x1b]1337;File=inline=1;size={decoded_len}:{TINY_PNG_B64}\x07",
                    raw,
                )
                self.assertNotIn("\x1b_G", raw)
                pty.send_text("/quit")
                pty.send_enter()
                self.assertEqual(pty.wait(), 0)

        # 3. Fullscreen mode with HI_INLINE_IMAGES=kitty or iterm2 emits only `[image: ...]` text
        for proto in ("kitty", "iterm2"):
            with self.subTest(proto=proto):
                with CutoverFakeDaemon(cwd=self.workdir) as daemon:
                    daemon.seed_assistant_image(text="fullscreen preview")
                    env = dict(daemon.env(), HI_INLINE_IMAGES=proto)
                    with PtySession(
                        [self.hi_bin, "-s", "demo", "--tui-mode", "fullscreen"],
                        env=env,
                        cwd=self.workdir,
                        rows=24,
                        cols=100,
                    ) as pty:
                        daemon.wait_for_sse_connect()
                        pty.wait_for_raw_mode()
                        pty.wait_for_output("[image: image/png")
                        raw = pty.raw_text()
                        self.assertNotIn("\x1b_G", raw)
                        self.assertNotIn("\x1b]1337;File=", raw)
                        pty.send_text("/quit")
                        pty.send_enter()
                        self.assertEqual(pty.wait(), 0)


if __name__ == "__main__":
    unittest.main()
