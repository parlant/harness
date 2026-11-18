"""Disposable fake H daemon (HTTP/1.1 + chunked SSE) for PTY acceptance tests.

Supports both Unix domain sockets (`<data_dir>/api.sock`) and loopback TCP
(`http://127.0.0.1:<port>`), enforcing H v1 owner bearer authentication and Host
header rules without any paid model or external network calls.
"""

from __future__ import annotations

import errno
import json
import os
import queue
import secrets
import shutil
import socket
import socketserver
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler
from typing import Any


def extract_content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and item.get("type") == "text":
                text = item.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    return ""


class _QuietMixIn(socketserver.ThreadingMixIn):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request: Any, client_address: Any) -> None:
        exc = sys.exc_info()[1] if "sys" in globals() else None
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, EOFError, OSError)):
            return
        super().handle_error(request, client_address)


class _ThreadingUnixStreamServer(_QuietMixIn, socketserver.UnixStreamServer):
    pass


class _ThreadingTCPServer(_QuietMixIn, socketserver.TCPServer):
    pass


class _SseSubscriber:
    def __init__(self, sid: str, cid: str) -> None:
        self.sid = sid
        self.cid = cid
        self.queue: queue.Queue[tuple[str, str | None, str] | None] = queue.Queue()
        self.closed = threading.Event()

    def push(self, event_name: str, event_id: str | None, payload: dict[str, Any]) -> None:
        if not self.closed.is_set():
            self.queue.put((event_name, event_id, json.dumps(payload, separators=(",", ":"))))

    def close(self) -> None:
        if not self.closed.is_set():
            self.closed.set()
            self.queue.put(None)


class FakeDaemon:
    """In-process disposable H daemon speaking the local v1 JSON/SSE protocol."""

    def __init__(
        self,
        *,
        transport: str = "uds",
        cwd: str | None = None,
        session_id: str = "demo",
        model_id: str = "fake/test-model",
    ) -> None:
        if transport not in ("uds", "tcp", "both"):
            raise ValueError(f"unsupported transport: {transport}")

        self.transport = transport
        self.cwd = os.path.abspath(cwd or os.getcwd())
        self.default_session_id = session_id
        self.model_id = model_id

        # Keep temp dir short on macOS/BSD because sun_path is capped at 104 bytes.
        self.data_dir = tempfile.mkdtemp(prefix="hipty-", dir="/tmp")
        self.token = f"tok_fake_{secrets.token_hex(8)}"
        with open(os.path.join(self.data_dir, "auth.token"), "w", encoding="utf-8") as f:
            f.write(self.token + "\n")

        self._lock = threading.RLock()
        self._cond = threading.Condition(self._lock)

        self.recorded_requests: list[dict[str, Any]] = []
        self.recorded_commands: list[dict[str, Any]] = []
        self.sse_connect_count = 0
        self.sse_disconnect_count = 0

        self._sessions: dict[str, dict[str, Any]] = {}
        self._subscribers: list[_SseSubscriber] = []
        self._turn_threads: list[threading.Thread] = []
        self._stop_event = threading.Event()

        # Configurable turn pacing for deterministic PTY tests.
        self._next_stream_chunks: list[str] = ["Alpha ", "Beta ", "Gamma"]
        self._next_stream_gate: threading.Event | None = None
        self._next_chunk_delay_s: float = 0.02

        self._create_session_locked(
            session_id=self.default_session_id,
            env_id="host",
            cwd=self.cwd,
            title="Demo Session",
            model=self.model_id,
            thinking="medium",
        )

        self._unix_server: _ThreadingUnixStreamServer | None = None
        self._tcp_server: _ThreadingTCPServer | None = None
        self._server_threads: list[threading.Thread] = []
        self.socket_path: str | None = None
        self.http_url: str | None = None
        self.port: int | None = None

    def start(self) -> "FakeDaemon":
        handler_cls = self._make_handler_class()

        if self.transport in ("tcp", "both"):
            self._tcp_server = _ThreadingTCPServer(("127.0.0.1", 0), handler_cls)
            self.port = int(self._tcp_server.server_address[1])
            self.http_url = f"http://127.0.0.1:{self.port}"
            t = threading.Thread(target=self._tcp_server.serve_forever, daemon=True)
            t.start()
            self._server_threads.append(t)

        if self.transport in ("uds", "both"):
            self.socket_path = os.path.join(self.data_dir, "api.sock")
            if os.path.exists(self.socket_path):
                os.unlink(self.socket_path)
            self._unix_server = _ThreadingUnixStreamServer(self.socket_path, handler_cls)
            t = threading.Thread(target=self._unix_server.serve_forever, daemon=True)
            t.start()
            self._server_threads.append(t)

        manifest = {
            "version": 1,
            "pid": os.getpid(),
            "http_url": self.http_url,
            "api_socket": self.socket_path,
        }
        with open(os.path.join(self.data_dir, "daemon.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f)

        return self

    def stop(self) -> None:
        self._stop_event.set()
        with self._lock:
            if self._next_stream_gate is not None:
                self._next_stream_gate.set()
            for sess in self._sessions.values():
                for conv in sess["conversations"].values():
                    gate = conv.get("active_gate")
                    if gate is not None:
                        gate.set()
            for sub in list(self._subscribers):
                sub.close()
            self._cond.notify_all()

        if self._unix_server is not None:
            self._unix_server.shutdown()
            self._unix_server.server_close()
            self._unix_server = None
        if self._tcp_server is not None:
            self._tcp_server.shutdown()
            self._tcp_server.server_close()
            self._tcp_server = None

        for t in self._turn_threads:
            t.join(timeout=2.0)
        for t in self._server_threads:
            t.join(timeout=2.0)

        shutil.rmtree(self.data_dir, ignore_errors=True)

    def __enter__(self) -> "FakeDaemon":
        return self.start()

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.stop()

    def env(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        env = os.environ.copy()
        env["H_DATA_DIR"] = self.data_dir
        env.pop("H_DAEMON_URL", None)
        if self.transport == "tcp" and self.http_url:
            env["H_DAEMON_URL"] = self.http_url
        if extra:
            env.update(extra)
        return env

    # --- Test control helpers ---

    def arm_gated_stream(
        self,
        *,
        chunks: list[str] | None = None,
        chunk_delay_s: float = 0.01,
    ) -> threading.Event:
        """Gate the next started turn after emitting initial chunks until gate.set()."""
        gate = threading.Event()
        with self._lock:
            self._next_stream_chunks = list(chunks or ["Streaming part 1 ", "Streaming part 2 "])
            self._next_stream_gate = gate
            self._next_chunk_delay_s = chunk_delay_s
        return gate

    def arm_auto_stream(
        self,
        *,
        chunks: list[str] | None = None,
        chunk_delay_s: float = 0.01,
    ) -> None:
        """Configure the next started turn to stream chunks and complete without a gate."""
        with self._lock:
            self._next_stream_chunks = list(chunks or ["Fake response"])
            self._next_stream_gate = None
            self._next_chunk_delay_s = chunk_delay_s

    def emit_ephemeral_chunk(
        self,
        text: str,
        *,
        session_id: str | None = None,
        conversation_id: str = "1",
    ) -> None:
        sid = session_id or self.default_session_id
        with self._lock:
            sess = self._sessions[sid]
            conv = sess["conversations"][conversation_id]
            base_seq = conv["seq"]
            gen = conv["docs"]["live"].setdefault("generation", {"message": {"text": ""}})
            msg = gen.setdefault("message", {"text": ""})
            msg["text"] = msg.get("text", "") + text
            payload = {
                "version": 1,
                "session_id": sid,
                "conversation_id": conversation_id,
                "base_seq": base_seq,
                "doc_ops": {
                    "live": [["append_text", ["generation", "message", "text"], text]]
                },
            }
            self._broadcast_locked(sid, conversation_id, "ephemeral", None, payload)

    def wait_for_sse_connect(
        self,
        session_id: str | None = None,
        conversation_id: str = "1",
        *,
        min_count: int = 1,
        timeout: float = 5.0,
    ) -> None:
        sid = session_id or self.default_session_id
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                matching = [
                    s for s in self._subscribers if s.sid == sid and s.cid == conversation_id
                ]
                if self.sse_connect_count >= min_count and matching:
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"timed out waiting for SSE connect on {sid}/{conversation_id}"
                    )
                self._cond.wait(timeout=remaining)

    def wait_for_command(
        self,
        predicate: Any,
        *,
        timeout: float = 5.0,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                for cmd in self.recorded_commands:
                    if predicate(cmd):
                        return cmd
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"timed out waiting for command; recorded={self.recorded_commands!r}"
                    )
                self._cond.wait(timeout=remaining)
        raise RuntimeError("daemon stopped while waiting for command")

    def wait_for_stream_active(
        self,
        session_id: str | None = None,
        conversation_id: str = "1",
        *,
        min_ephemerals: int = 1,
        timeout: float = 5.0,
    ) -> None:
        sid = session_id or self.default_session_id
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                sess = self._sessions.get(sid)
                if sess:
                    conv = sess["conversations"].get(conversation_id)
                    if (
                        conv
                        and conv["active"]
                        and conv["ephemerals_sent"] >= min_ephemerals
                    ):
                        return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timed out waiting for active stream")
                self._cond.wait(timeout=remaining)

    def wait_for_turn_idle(
        self,
        session_id: str | None = None,
        conversation_id: str = "1",
        *,
        timeout: float = 5.0,
    ) -> None:
        sid = session_id or self.default_session_id
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                sess = self._sessions.get(sid)
                if sess:
                    conv = sess["conversations"].get(conversation_id)
                    if conv and not conv["active"] and not conv["inbox"]:
                        return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timed out waiting for turn idle")
                self._cond.wait(timeout=remaining)

    def abort_commands(self) -> list[dict[str, Any]]:
        with self._lock:
            return [c for c in self.recorded_commands if c.get("command") == "abort"]

    def submit_commands(self) -> list[dict[str, Any]]:
        with self._lock:
            return [c for c in self.recorded_commands if c.get("command") == "submit"]

    def conversation_entries(
        self, session_id: str | None = None, conversation_id: str = "1"
    ) -> list[dict[str, Any]]:
        sid = session_id or self.default_session_id
        with self._lock:
            return list(self._sessions[sid]["conversations"][conversation_id]["entries"])

    # --- Internal state & protocol handlers ---

    def _create_session_locked(
        self,
        *,
        session_id: str,
        env_id: str,
        cwd: str,
        title: str | None,
        model: str,
        thinking: str,
    ) -> dict[str, Any]:
        now = int(time.time())
        sess = {
            "session_id": session_id,
            "title": title,
            "env_id": env_id,
            "harness_id": "coding",
            "cwd": cwd,
            "root_conversation_id": "1",
            "created_at": now,
            "updated_at": now,
            "active": False,
            "next_wake_at": None,
            "status": "ok",
            "seq": 1,
            "next_entry_id": 1,
            "next_sub_id": 1,
            "next_conv_id": 2,
            "receipts": {},
            "conversations": {
                "1": {
                    "id": "1",
                    "parent": None,
                    "owner": "ownerless",
                    "seq": 1,
                    "entries": [],
                    "replay_ring": [],
                    "active": False,
                    "aborted": False,
                    "active_gate": None,
                    "ephemerals_sent": 0,
                    "inbox": [],
                    "docs": {
                        "live": {},
                        "inbox": [],
                        "agent": {"model": model, "thinking": thinking},
                        "usage": {"input_tokens": 0, "output_tokens": 0, "cost": 0.0},
                    },
                }
            },
        }
        self._sessions[session_id] = sess
        return sess

    def _wire_session_locked(self, sess: dict[str, Any]) -> dict[str, Any]:
        return {
            "session_id": sess["session_id"],
            "title": sess["title"],
            "env_id": sess["env_id"],
            "harness_id": sess["harness_id"],
            "cwd": sess["cwd"],
            "root_conversation_id": sess["root_conversation_id"],
            "created_at": sess["created_at"],
            "updated_at": sess["updated_at"],
            "active": sess["active"],
            "next_wake_at": sess["next_wake_at"],
            "status": sess["status"],
        }

    def _broadcast_locked(
        self,
        sid: str,
        cid: str,
        event_name: str,
        event_id: str | None,
        payload: dict[str, Any],
    ) -> None:
        alive: list[_SseSubscriber] = []
        for sub in self._subscribers:
            if sub.closed.is_set():
                continue
            alive.append(sub)
            if sub.sid == sid and sub.cid == cid:
                sub.push(event_name, event_id, payload)
        self._subscribers = alive

    def _commit_locked(
        self,
        sess: dict[str, Any],
        conv: dict[str, Any],
        *,
        appended_entries: list[dict[str, Any]] | None = None,
        doc_ops: dict[str, Any] | None = None,
    ) -> int:
        prev_seq = conv["seq"]
        sess["seq"] += 1
        new_seq = sess["seq"]
        conv["seq"] = new_seq
        sess["updated_at"] = int(time.time())

        entries = appended_entries or []
        for e in entries:
            conv["entries"].append(e)

        frame: dict[str, Any] = {
            "version": 1,
            "session_id": sess["session_id"],
            "conversation_id": conv["id"],
            "prev_seq": prev_seq,
            "seq": new_seq,
            "appended_entries": entries,
        }
        if doc_ops is not None:
            frame["doc_ops"] = doc_ops

        conv["replay_ring"].append((new_seq, frame))
        if len(conv["replay_ring"]) > 64:
            conv["replay_ring"] = conv["replay_ring"][-64:]

        self._broadcast_locked(sess["session_id"], conv["id"], "commit", str(new_seq), frame)
        self._cond.notify_all()
        return new_seq

    def _next_entry_locked(
        self,
        sess: dict[str, Any],
        conv: dict[str, Any],
        kind: str,
        data: dict[str, Any],
    ) -> dict[str, Any]:
        eid = str(sess["next_entry_id"])
        sess["next_entry_id"] += 1
        return {
            "id": eid,
            "conversation_id": conv["id"],
            "seq": sess["seq"] + 1,
            "kind": kind,
            "data": data,
            "created_at": int(time.time()),
        }

    def _start_turn_locked(self, sess: dict[str, Any], conv: dict[str, Any], text: str) -> int:
        conv["active"] = True
        conv["aborted"] = False
        conv["ephemerals_sent"] = 0
        sess["active"] = True

        chunks = list(self._next_stream_chunks)
        gate = self._next_stream_gate
        chunk_delay = self._next_chunk_delay_s
        # Reset one-shot gated configuration so subsequent turns don't stall unexpectedly.
        self._next_stream_chunks = ["Fake response to: " + text]
        self._next_stream_gate = None
        self._next_chunk_delay_s = 0.01
        conv["active_gate"] = gate

        user_entry = self._next_entry_locked(
            sess,
            conv,
            "user",
            {"content": [{"type": "text", "text": text}]},
        )
        live_doc = {"run": {"turns": 1}, "generation": {"message": {"text": ""}}}
        conv["docs"]["live"] = live_doc
        commit_seq = self._commit_locked(
            sess,
            conv,
            appended_entries=[user_entry],
            doc_ops={"live": [["replace", live_doc]]},
        )

        worker = threading.Thread(
            target=self._run_turn_worker,
            args=(sess["session_id"], conv["id"], text, chunks, gate, chunk_delay),
            daemon=True,
        )
        self._turn_threads.append(worker)
        worker.start()
        return commit_seq

    def _run_turn_worker(
        self,
        sid: str,
        cid: str,
        prompt_text: str,
        chunks: list[str],
        gate: threading.Event | None,
        chunk_delay: float,
    ) -> None:
        full_parts: list[str] = []
        for idx, chunk in enumerate(chunks):
            if self._stop_event.is_set():
                return
            if chunk_delay > 0:
                time.sleep(chunk_delay)
            with self._lock:
                sess = self._sessions.get(sid)
                if not sess:
                    return
                conv = sess["conversations"].get(cid)
                if not conv or not conv["active"] or conv["aborted"]:
                    return
                full_parts.append(chunk)
                conv["ephemerals_sent"] += 1
                gen = conv["docs"]["live"].setdefault("generation", {"message": {"text": ""}})
                msg = gen.setdefault("message", {"text": ""})
                msg["text"] = msg.get("text", "") + chunk
                payload = {
                    "version": 1,
                    "session_id": sid,
                    "conversation_id": cid,
                    "base_seq": conv["seq"],
                    "doc_ops": {
                        "live": [["append_text", ["generation", "message", "text"], chunk]]
                    },
                }
                self._broadcast_locked(sid, cid, "ephemeral", None, payload)
                self._cond.notify_all()
            # If gated, wait after emitting initial chunks so PTY tests observe active stream.
            if gate is not None and idx == len(chunks) - 1:
                gate.wait(timeout=10.0)

        with self._lock:
            sess = self._sessions.get(sid)
            if not sess:
                return
            conv = sess["conversations"].get(cid)
            if not conv or not conv["active"] or conv["aborted"]:
                return
            conv["active_gate"] = None
            assistant_text = "".join(full_parts) or f"Done: {prompt_text}"
            assistant_entry = self._next_entry_locked(
                sess,
                conv,
                "assistant",
                {"content": [{"type": "text", "text": assistant_text}]},
            )
            conv["docs"]["live"] = {}
            usage = conv["docs"]["usage"]
            usage["input_tokens"] += max(1, len(prompt_text.split()))
            usage["output_tokens"] += max(1, len(assistant_text.split()))
            self._commit_locked(
                sess,
                conv,
                appended_entries=[assistant_entry],
                doc_ops={"live": [["replace", {}]], "usage": [["replace", dict(usage)]]},
            )

            # Drain next queued steer / follow_up item if present.
            if conv["inbox"] and not self._stop_event.is_set():
                queued = conv["inbox"].pop(0)
                conv["docs"]["inbox"] = list(conv["inbox"])
                self._commit_locked(
                    sess,
                    conv,
                    doc_ops={"inbox": [["replace", list(conv["inbox"])]]},
                )
                self._start_turn_locked(sess, conv, queued["text"])
            else:
                conv["active"] = False
                sess["active"] = False
                self._cond.notify_all()

    def _execute_command_locked(
        self, sid: str, raw: dict[str, Any]
    ) -> tuple[int, dict[str, Any]]:
        sess = self._sessions.get(sid)
        if not sess:
            return 404, {"error": "not found"}

        if raw.get("version") != 1:
            return 422, {"error": "version must be 1"}
        req_id = raw.get("request_id")
        command = raw.get("command")
        cid_raw = raw.get("conversation_id")
        args = raw.get("args")
        if not isinstance(req_id, str) or not req_id:
            return 422, {"error": "request_id required"}
        if command not in ("submit", "fork", "fork_and_submit", "configure", "abort"):
            return 422, {"error": "unsupported command"}
        if not isinstance(cid_raw, int) or cid_raw <= 0:
            return 422, {"error": "conversation_id must be positive int"}
        if args is None:
            args = {}
        if not isinstance(args, dict):
            return 422, {"error": "args must be object"}

        cid = str(cid_raw)
        conv = sess["conversations"].get(cid)
        if not conv:
            return 404, {"error": "not found"}

        normalized_key = json.dumps(
            {"command": command, "conversation_id": cid_raw, "args": args},
            sort_keys=True,
        )
        if req_id in sess["receipts"]:
            prev_key, prev_receipt = sess["receipts"][req_id]
            if prev_key != normalized_key:
                return 409, {"error": "request_id reused with different payload"}
            return 200, prev_receipt

        record = {
            "session_id": sid,
            "version": 1,
            "request_id": req_id,
            "conversation_id": cid_raw,
            "command": command,
            "args": args,
        }
        self.recorded_commands.append(record)

        if command == "submit":
            sub_type = args.get("type")
            if sub_type == "input":
                text = extract_content_text(args.get("content"))
                if not text:
                    return 422, {"error": "content must be non-empty"}
                when_busy = args.get("when_busy", "follow_up")
                when_idle = args.get("when_idle", "start")
                sub_id = f"sub-{sess['next_sub_id']}"
                sess["next_sub_id"] += 1

                if conv["active"]:
                    if when_busy == "reject":
                        return 409, {"error": "conversation is busy"}
                    item = {"id": sub_id, "mode": when_busy, "text": text}
                    if when_busy == "steer":
                        conv["inbox"].insert(0, item)
                    else:
                        conv["inbox"].append(item)
                    conv["docs"]["inbox"] = list(conv["inbox"])
                    seq = self._commit_locked(
                        sess,
                        conv,
                        doc_ops={"inbox": [["replace", list(conv["inbox"])]]},
                    )
                    receipt = {
                        "version": 1,
                        "request_id": req_id,
                        "seq": seq,
                        "submission_id": sub_id,
                        "status": "queued",
                    }
                else:
                    if when_idle == "reject":
                        return 409, {"error": "conversation is idle"}
                    seq = self._start_turn_locked(sess, conv, text)
                    receipt = {
                        "version": 1,
                        "request_id": req_id,
                        "seq": seq,
                        "submission_id": sub_id,
                        "status": "started",
                    }
            elif sub_type == "continue":
                seq = self._start_turn_locked(sess, conv, "continue")
                receipt = {"version": 1, "request_id": req_id, "seq": seq, "status": "started"}
            else:
                return 422, {"error": "unsupported submit type"}

        elif command == "abort":
            conv["aborted"] = True
            conv["active"] = False
            sess["active"] = False
            if conv.get("active_gate") is not None:
                conv["active_gate"].set()
            conv["docs"]["live"] = {}
            aborted_entry = self._next_entry_locked(
                sess,
                conv,
                "assistant",
                {"content": [{"type": "text", "text": "[aborted]"}], "aborted": True},
            )
            seq = self._commit_locked(
                sess,
                conv,
                appended_entries=[aborted_entry],
                doc_ops={"live": [["replace", {}]]},
            )
            receipt = {"version": 1, "request_id": req_id, "seq": seq, "status": "aborted"}

        elif command == "configure":
            agent = dict(conv["docs"]["agent"])
            if args.get("model"):
                agent["model"] = args["model"]
            if args.get("thinking"):
                agent["thinking"] = args["thinking"]
            conv["docs"]["agent"] = agent
            seq = self._commit_locked(
                sess,
                conv,
                doc_ops={"agent": [["replace", agent]]},
            )
            receipt = {"version": 1, "request_id": req_id, "seq": seq, "status": "configured"}

        elif command in ("fork", "fork_and_submit"):
            at_id = str(args.get("at_entry_id", "1"))
            new_cid = str(sess["next_conv_id"])
            sess["next_conv_id"] += 1
            parent_entries = [e for e in conv["entries"] if int(e["id"]) <= int(at_id)]
            sess["conversations"][new_cid] = {
                "id": new_cid,
                "parent": {"conversation_id": cid, "at": at_id},
                "owner": "ownerless",
                "seq": sess["seq"],
                "entries": list(parent_entries),
                "replay_ring": [],
                "active": False,
                "aborted": False,
                "active_gate": None,
                "ephemerals_sent": 0,
                "inbox": [],
                "docs": {
                    "live": {},
                    "inbox": [],
                    "agent": dict(conv["docs"]["agent"]),
                    "usage": {"input_tokens": 0, "output_tokens": 0, "cost": 0.0},
                },
            }
            receipt = {
                "version": 1,
                "request_id": req_id,
                "seq": sess["seq"],
                "conversation_id": new_cid,
                "status": "forked",
            }
        else:
            return 422, {"error": "unsupported command"}

        sess["receipts"][req_id] = (normalized_key, receipt)
        self._cond.notify_all()
        return 200, receipt

    def _make_handler_class(self) -> type[BaseHTTPRequestHandler]:
        daemon = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def address_string(self) -> str:
                if isinstance(self.client_address, (str, bytes)) or not self.client_address:
                    return "unix"
                return str(self.client_address[0])

            def _is_authorized_and_valid_host(self) -> bool:
                host = self.headers.get("Host", "").strip()
                if not host:
                    self._send_json(421, {"error": "missing Host header"})
                    return False
                if isinstance(self.client_address, tuple) and daemon.port is not None:
                    expected = f"127.0.0.1:{daemon.port}"
                    if host != expected:
                        self._send_json(421, {"error": f"disallowed Host {host}"})
                        return False

                auth = self.headers.get("Authorization", "")
                if auth != f"Bearer {daemon.token}":
                    self._send_json(401, {"error": "unauthorized"})
                    return False
                return True

            def _send_json(self, status: int, payload: Any) -> None:
                body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                self.close_connection = True

            def _record_req(self, method: str, path: str) -> None:
                with daemon._lock:
                    daemon.recorded_requests.append({"method": method, "path": path})

            def do_GET(self) -> None:
                if not self._is_authorized_and_valid_host():
                    return
                parsed = urllib.parse.urlparse(self.path)
                path = parsed.path
                query = urllib.parse.parse_qs(parsed.query)
                self._record_req("GET", path)

                if path == "/api/v1/environments":
                    self._send_json(
                        200,
                        {
                            "environments": [
                                {
                                    "id": "host",
                                    "kind": "host",
                                    "label": "Host",
                                    "default_cwd": daemon.cwd,
                                }
                            ]
                        },
                    )
                    return

                if path == "/api/v1/models":
                    self._send_json(
                        200,
                        {
                            "models": [
                                {
                                    "id": daemon.model_id,
                                    "name": "Fake Test Model",
                                    "provider": "fake",
                                }
                            ]
                        },
                    )
                    return

                if path == "/api/v1/sessions":
                    env_filter = query.get("env_id", [None])[0]
                    cwd_filter = query.get("cwd", [None])[0]
                    with daemon._lock:
                        out = []
                        for sess in daemon._sessions.values():
                            if env_filter and sess["env_id"] != env_filter:
                                continue
                            if cwd_filter and sess["cwd"] != cwd_filter:
                                continue
                            out.append(daemon._wire_session_locked(sess))
                    self._send_json(200, {"sessions": out})
                    return

                parts = [p for p in path.split("/") if p]
                # /api/v1/sessions/:sid
                if len(parts) == 4 and parts[:3] == ["api", "v1", "sessions"]:
                    sid = urllib.parse.unquote(parts[3])
                    with daemon._lock:
                        sess = daemon._sessions.get(sid)
                        if not sess:
                            self._send_json(404, {"error": "session not found"})
                            return
                        convs = [
                            {"id": c["id"], "parent": c["parent"], "owner": c["owner"]}
                            for c in sess["conversations"].values()
                        ]
                        detail = {
                            "session": daemon._wire_session_locked(sess),
                            "conversations": convs,
                            "tasks": [],
                        }
                    self._send_json(200, detail)
                    return

                # /api/v1/sessions/:sid/conversations/:cid/entries
                if (
                    len(parts) == 7
                    and parts[:3] == ["api", "v1", "sessions"]
                    and parts[4] == "conversations"
                    and parts[6] == "entries"
                ):
                    sid = urllib.parse.unquote(parts[3])
                    cid = urllib.parse.unquote(parts[5])
                    order = query.get("order", ["desc"])[0]
                    cursor = query.get("cursor", [None])[0]
                    limit = int(query.get("limit", ["50"])[0])
                    with daemon._lock:
                        sess = daemon._sessions.get(sid)
                        conv = sess["conversations"].get(cid) if sess else None
                        if not conv:
                            self._send_json(404, {"error": "not found"})
                            return
                        entries = list(conv["entries"])
                    if cursor is not None:
                        entries = [e for e in entries if int(e["id"]) < int(cursor)]
                    if order == "desc":
                        entries.reverse()
                    page = entries[:limit]
                    next_cursor = None
                    if len(entries) > limit and page:
                        next_cursor = page[-1]["id"]
                    self._send_json(200, {"items": page, "next_cursor": next_cursor})
                    return

                # /api/v1/sessions/:sid/conversations/:cid/events
                if (
                    len(parts) == 7
                    and parts[:3] == ["api", "v1", "sessions"]
                    and parts[4] == "conversations"
                    and parts[6] == "events"
                ):
                    sid = urllib.parse.unquote(parts[3])
                    cid = urllib.parse.unquote(parts[5])
                    last_id_raw = self.headers.get("Last-Event-ID") or query.get(
                        "last_event_id", [None]
                    )[0]
                    last_id = int(last_id_raw) if last_id_raw and last_id_raw.isdigit() else None
                    self._handle_sse(sid, cid, last_id)
                    return

                self._send_json(404, {"error": "not found"})

            def do_POST(self) -> None:
                if not self._is_authorized_and_valid_host():
                    return
                parsed = urllib.parse.urlparse(self.path)
                path = parsed.path
                self._record_req("POST", path)

                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length) if length > 0 else b"{}"
                try:
                    body = json.loads(raw_body.decode("utf-8"))
                except Exception as exc:
                    self._send_json(422, {"error": f"invalid json: {exc}"})
                    return

                if path == "/api/v1/sessions":
                    cwd = body.get("cwd")
                    if not isinstance(cwd, str) or not cwd.startswith("/"):
                        self._send_json(422, {"error": "cwd must be absolute"})
                        return
                    sid = body.get("session_id") or f"demo-{secrets.token_hex(4)}"
                    env_id = body.get("env_id") or "host"
                    with daemon._lock:
                        existing = daemon._sessions.get(sid)
                        if existing:
                            if existing["cwd"] != cwd or existing["env_id"] != env_id:
                                self._send_json(409, {"error": "workspace conflict"})
                                return
                            resp = {
                                "session": daemon._wire_session_locked(existing),
                                "seq": existing["seq"],
                            }
                        else:
                            created = daemon._create_session_locked(
                                session_id=sid,
                                env_id=env_id,
                                cwd=cwd,
                                title=body.get("title"),
                                model=daemon.model_id,
                                thinking="medium",
                            )
                            resp = {
                                "session": daemon._wire_session_locked(created),
                                "seq": created["seq"],
                            }
                    self._send_json(200, resp)
                    return

                parts = [p for p in path.split("/") if p]
                if (
                    len(parts) == 5
                    and parts[:3] == ["api", "v1", "sessions"]
                    and parts[4] == "commands"
                ):
                    sid = urllib.parse.unquote(parts[3])
                    with daemon._lock:
                        status, payload = daemon._execute_command_locked(sid, body)
                    self._send_json(status, payload)
                    return

                self._send_json(404, {"error": "not found"})

            def _write_chunk(self, text: str) -> None:
                data = text.encode("utf-8")
                header = f"{len(data):x}\r\n".encode("ascii")
                self.wfile.write(header + data + b"\r\n")
                self.wfile.flush()

            def _handle_sse(self, sid: str, cid: str, last_id: int | None) -> None:
                sub = _SseSubscriber(sid, cid)
                initial_frames: list[tuple[str, str | None, dict[str, Any]]] = []

                with daemon._lock:
                    sess = daemon._sessions.get(sid)
                    conv = sess["conversations"].get(cid) if sess else None
                    if not conv:
                        self._send_json(404, {"error": "not found"})
                        return

                    daemon._subscribers.append(sub)
                    daemon.sse_connect_count += 1

                    ring = conv["replay_ring"]
                    if last_id is not None and ring and last_id >= ring[0][0] - 1:
                        for seq, frame in ring:
                            if seq > last_id:
                                initial_frames.append(("commit", str(seq), frame))
                    else:
                        snap = {
                            "version": 1,
                            "session_id": sid,
                            "conversation_id": cid,
                            "seq": conv["seq"],
                            "before_entry_id": None,
                            "has_more": False,
                            "entries": list(conv["entries"][-50:]),
                            "docs": json.loads(json.dumps(conv["docs"])),
                        }
                        initial_frames.append(("snapshot", str(conv["seq"]), snap))
                    daemon._cond.notify_all()

                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Transfer-Encoding", "chunked")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True

                try:
                    for ev_name, ev_id, payload in initial_frames:
                        frame_txt = _format_sse(
                            ev_name, ev_id, json.dumps(payload, separators=(",", ":"))
                        )
                        self._write_chunk(frame_txt)

                    while not daemon._stop_event.is_set() and not sub.closed.is_set():
                        try:
                            item = sub.queue.get(timeout=0.5)
                        except queue.Empty:
                            try:
                                self._write_chunk(": keepalive\n\n")
                            except OSError:
                                break
                            continue
                        if item is None:
                            break
                        ev_name, ev_id, data_json = item
                        self._write_chunk(_format_sse(ev_name, ev_id, data_json))
                except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                    if getattr(exc, "errno", None) not in (
                        errno.EPIPE,
                        errno.ECONNRESET,
                        errno.EBADF,
                        None,
                    ):
                        pass
                finally:
                    sub.close()
                    with daemon._lock:
                        daemon.sse_disconnect_count += 1
                        daemon._subscribers = [s for s in daemon._subscribers if s is not sub]
                        daemon._cond.notify_all()

        return Handler


def _format_sse(event_name: str, event_id: str | None, data_json: str) -> str:
    lines: list[str] = []
    if event_id is not None:
        lines.append(f"id: {event_id}")
    lines.append(f"event: {event_name}")
    lines.append(f"data: {data_json}")
    return "\n".join(lines) + "\n\n"
