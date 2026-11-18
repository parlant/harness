"""Minimal disposable fake H daemon (HTTP/1.1 + chunked SSE) for PTY tests."""

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
        exc = sys.exc_info()[1]
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
    """Minimal disposable H daemon speaking the local v1 JSON/SSE protocol."""

    def __init__(
        self,
        *,
        transport: str = "uds",
        cwd: str | None = None,
        session_id: str = "demo",
    ) -> None:
        if transport not in ("uds", "tcp"):
            raise ValueError(f"unsupported transport: {transport}")

        self.transport = transport
        self.cwd = os.path.abspath(cwd or os.getcwd())
        self.session_id = session_id
        self.model_id = "fake/test-model"

        # Keep path short for macOS 104-byte sun_path limit.
        self.data_dir = tempfile.mkdtemp(prefix="hipty-", dir="/tmp")
        self.token = f"tok_fake_{secrets.token_hex(8)}"
        with open(os.path.join(self.data_dir, "auth.token"), "w", encoding="utf-8") as f:
            f.write(self.token + "\n")

        self._lock = threading.RLock()
        self._cond = threading.Condition(self._lock)
        self._stop_event = threading.Event()

        self.recorded_commands: list[dict[str, Any]] = []
        self.sse_connect_count = 0

        self._seq = 1
        self._next_entry_id = 1
        self._next_sub_id = 1
        self._entries: list[dict[str, Any]] = []
        self._active = False
        self._aborted = False
        self._active_gate: threading.Event | None = None
        self._ephemerals_sent = 0
        self._inbox: list[dict[str, Any]] = []
        self._docs: dict[str, Any] = {
            "live": {},
            "inbox": [],
            "agent": {"model": self.model_id, "thinking": "medium"},
            "usage": {"input_tokens": 0, "output_tokens": 0, "cost": 0.0},
        }

        self._next_chunks: list[str] = ["Fake response"]
        self._next_gate: threading.Event | None = None

        self._subscribers: list[_SseSubscriber] = []
        self._turn_threads: list[threading.Thread] = []
        self._server: _ThreadingUnixStreamServer | _ThreadingTCPServer | None = None
        self._server_thread: threading.Thread | None = None
        self.socket_path: str | None = None
        self.http_url: str | None = None
        self.port: int | None = None

    def start(self) -> "FakeDaemon":
        handler_cls = self._make_handler_class()
        if self.transport == "tcp":
            self._server = _ThreadingTCPServer(("127.0.0.1", 0), handler_cls)
            self.port = int(self._server.server_address[1])
            self.http_url = f"http://127.0.0.1:{self.port}"
        else:
            self.socket_path = os.path.join(self.data_dir, "api.sock")
            self._server = _ThreadingUnixStreamServer(self.socket_path, handler_cls)

        self._server_thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._server_thread.start()

        with open(os.path.join(self.data_dir, "daemon.json"), "w", encoding="utf-8") as f:
            json.dump(
                {
                    "version": 1,
                    "pid": os.getpid(),
                    "http_url": self.http_url,
                    "api_socket": self.socket_path,
                },
                f,
            )
        return self

    def stop(self) -> None:
        self._stop_event.set()
        with self._lock:
            if self._next_gate is not None:
                self._next_gate.set()
            if self._active_gate is not None:
                self._active_gate.set()
            for sub in list(self._subscribers):
                sub.close()
            self._cond.notify_all()

        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        for t in self._turn_threads:
            t.join(timeout=2.0)
        if self._server_thread is not None:
            self._server_thread.join(timeout=2.0)
        shutil.rmtree(self.data_dir, ignore_errors=True)

    def __enter__(self) -> "FakeDaemon":
        return self.start()

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.stop()

    def env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["H_DATA_DIR"] = self.data_dir
        env.pop("H_DAEMON_URL", None)
        if self.transport == "tcp" and self.http_url:
            env["H_DAEMON_URL"] = self.http_url
        return env

    # --- Test controls ---

    def arm_gated_stream(self, *, chunks: list[str]) -> threading.Event:
        gate = threading.Event()
        with self._lock:
            self._next_chunks = list(chunks)
            self._next_gate = gate
        return gate

    def arm_auto_stream(self, *, chunks: list[str]) -> None:
        with self._lock:
            self._next_chunks = list(chunks)
            self._next_gate = None

    def emit_ephemeral_chunk(self, text: str) -> None:
        with self._lock:
            gen = self._docs["live"].setdefault("generation", {"message": {"text": ""}})
            msg = gen.setdefault("message", {"text": ""})
            msg["text"] = msg.get("text", "") + text
            self._broadcast_locked(
                "ephemeral",
                None,
                {
                    "version": 1,
                    "session_id": self.session_id,
                    "conversation_id": "1",
                    "base_seq": self._seq,
                    "doc_ops": {
                        "live": [["append_text", ["generation", "message", "text"], text]]
                    },
                },
            )

    def wait_for_sse_connect(self, *, min_count: int = 1, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                if self.sse_connect_count >= min_count and self._subscribers:
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timed out waiting for SSE connect")
                self._cond.wait(timeout=remaining)

    def wait_for_stream_active(self, *, min_ephemerals: int = 1, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                if self._active and self._ephemerals_sent >= min_ephemerals:
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timed out waiting for active stream")
                self._cond.wait(timeout=remaining)

    def wait_for_turn_idle(self, *, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                if not self._active and not self._inbox:
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timed out waiting for turn idle")
                self._cond.wait(timeout=remaining)

    def wait_for_command(self, predicate: Any, *, timeout: float = 5.0) -> dict[str, Any]:
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
        raise RuntimeError("daemon stopped")

    def abort_commands(self) -> list[dict[str, Any]]:
        with self._lock:
            return [c for c in self.recorded_commands if c.get("command") == "abort"]

    def conversation_entries(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._entries)

    # --- Internal state & protocol ---

    def _wire_session(self) -> dict[str, Any]:
        now = int(time.time())
        return {
            "session_id": self.session_id,
            "title": "Demo Session",
            "env_id": "host",
            "harness_id": "coding",
            "cwd": self.cwd,
            "root_conversation_id": "1",
            "created_at": now,
            "updated_at": now,
            "active": self._active,
            "next_wake_at": None,
            "status": "ok",
        }

    def _broadcast_locked(
        self, event_name: str, event_id: str | None, payload: dict[str, Any]
    ) -> None:
        self._subscribers = [s for s in self._subscribers if not s.closed.is_set()]
        for sub in self._subscribers:
            sub.push(event_name, event_id, payload)

    def _commit_locked(
        self,
        *,
        appended_entries: list[dict[str, Any]] | None = None,
        doc_ops: dict[str, Any] | None = None,
    ) -> int:
        prev_seq = self._seq
        self._seq += 1
        entries = appended_entries or []
        self._entries.extend(entries)
        frame: dict[str, Any] = {
            "version": 1,
            "session_id": self.session_id,
            "conversation_id": "1",
            "prev_seq": prev_seq,
            "seq": self._seq,
            "appended_entries": entries,
        }
        if doc_ops is not None:
            frame["doc_ops"] = doc_ops
        self._broadcast_locked("commit", str(self._seq), frame)
        self._cond.notify_all()
        return self._seq

    def _next_entry_locked(self, kind: str, data: dict[str, Any]) -> dict[str, Any]:
        eid = str(self._next_entry_id)
        self._next_entry_id += 1
        return {
            "id": eid,
            "conversation_id": "1",
            "seq": self._seq + 1,
            "kind": kind,
            "data": data,
            "created_at": int(time.time()),
        }

    def _start_turn_locked(self, prompt_text: str) -> int:
        self._active = True
        self._aborted = False
        self._ephemerals_sent = 0
        chunks = list(self._next_chunks)
        gate = self._next_gate
        self._next_chunks = [f"Reply: {prompt_text}"]
        self._next_gate = None
        self._active_gate = gate

        user_entry = self._next_entry_locked(
            "user", {"content": [{"type": "text", "text": prompt_text}]}
        )
        live_doc = {"run": {"turns": 1}, "generation": {"message": {"text": ""}}}
        self._docs["live"] = live_doc
        seq = self._commit_locked(
            appended_entries=[user_entry],
            doc_ops={"live": [["replace", live_doc]]},
        )
        t = threading.Thread(
            target=self._run_turn_worker,
            args=(prompt_text, chunks, gate),
            daemon=True,
        )
        self._turn_threads.append(t)
        t.start()
        return seq

    def _run_turn_worker(
        self, prompt_text: str, chunks: list[str], gate: threading.Event | None
    ) -> None:
        parts: list[str] = []
        for idx, chunk in enumerate(chunks):
            if self._stop_event.is_set():
                return
            time.sleep(0.01)
            with self._lock:
                if not self._active or self._aborted:
                    return
                parts.append(chunk)
                self._ephemerals_sent += 1
                self.emit_ephemeral_chunk(chunk)
                self._cond.notify_all()
            if gate is not None and idx == len(chunks) - 1:
                gate.wait(timeout=10.0)

        with self._lock:
            if not self._active or self._aborted:
                return
            self._active_gate = None
            assistant_text = "".join(parts) or f"Reply: {prompt_text}"
            assistant_entry = self._next_entry_locked(
                "assistant", {"content": [{"type": "text", "text": assistant_text}]}
            )
            self._docs["live"] = {}
            self._commit_locked(
                appended_entries=[assistant_entry],
                doc_ops={"live": [["replace", {}]]},
            )
            if self._inbox and not self._stop_event.is_set():
                queued = self._inbox.pop(0)
                self._docs["inbox"] = list(self._inbox)
                self._commit_locked(doc_ops={"inbox": [["replace", list(self._inbox)]]})
                self._start_turn_locked(queued["text"])
            else:
                self._active = False
                self._cond.notify_all()

    def _execute_command_locked(self, raw: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        req_id = raw.get("request_id")
        command = raw.get("command")
        cid_raw = raw.get("conversation_id")
        args = raw.get("args") or {}
        if raw.get("version") != 1 or not isinstance(req_id, str) or cid_raw != 1:
            return 422, {"error": "invalid command envelope"}

        self.recorded_commands.append(
            {
                "version": 1,
                "request_id": req_id,
                "conversation_id": cid_raw,
                "command": command,
                "args": args,
            }
        )

        if command == "submit" and args.get("type") == "input":
            text = extract_content_text(args.get("content"))
            if not text:
                return 422, {"error": "content required"}
            when_busy = args.get("when_busy", "follow_up")
            sub_id = f"sub-{self._next_sub_id}"
            self._next_sub_id += 1
            if self._active:
                item = {"id": sub_id, "mode": when_busy, "text": text}
                if when_busy == "steer":
                    self._inbox.insert(0, item)
                else:
                    self._inbox.append(item)
                self._docs["inbox"] = list(self._inbox)
                seq = self._commit_locked(doc_ops={"inbox": [["replace", list(self._inbox)]]})
                status = "queued"
            else:
                seq = self._start_turn_locked(text)
                status = "started"
            self._cond.notify_all()
            return 200, {
                "version": 1,
                "request_id": req_id,
                "seq": seq,
                "submission_id": sub_id,
                "status": status,
            }

        if command == "abort":
            self._aborted = True
            self._active = False
            if self._active_gate is not None:
                self._active_gate.set()
            self._docs["live"] = {}
            seq = self._commit_locked(doc_ops={"live": [["replace", {}]]})
            self._cond.notify_all()
            return 200, {"version": 1, "request_id": req_id, "seq": seq, "status": "aborted"}

        return 422, {"error": f"unsupported command: {command}"}

    def _make_handler_class(self) -> type[BaseHTTPRequestHandler]:
        daemon = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def _check_auth_and_host(self) -> bool:
                host = self.headers.get("Host", "").strip()
                if not host:
                    self._send_json(421, {"error": "missing Host"})
                    return False
                if isinstance(self.client_address, tuple) and daemon.port is not None:
                    if host != f"127.0.0.1:{daemon.port}":
                        self._send_json(421, {"error": "disallowed Host"})
                        return False
                if self.headers.get("Authorization", "") != f"Bearer {daemon.token}":
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

            def do_GET(self) -> None:
                if not self._check_auth_and_host():
                    return
                path = urllib.parse.urlparse(self.path).path
                if path == "/api/v1/environments":
                    self._send_json(
                        200,
                        {"environments": [{"id": "host", "kind": "host", "default_cwd": daemon.cwd}]},
                    )
                    return
                if path == "/api/v1/models":
                    self._send_json(
                        200,
                        {"models": [{"id": daemon.model_id, "name": "Fake", "provider": "fake"}]},
                    )
                    return
                if path == "/api/v1/sessions":
                    with daemon._lock:
                        self._send_json(200, {"sessions": [daemon._wire_session()]})
                    return
                if path == f"/api/v1/sessions/{daemon.session_id}":
                    with daemon._lock:
                        self._send_json(
                            200,
                            {
                                "session": daemon._wire_session(),
                                "conversations": [{"id": "1", "parent": None, "owner": "ownerless"}],
                                "tasks": [],
                            },
                        )
                    return
                if path == f"/api/v1/sessions/{daemon.session_id}/conversations/1/events":
                    self._handle_sse()
                    return
                self._send_json(404, {"error": "not found"})

            def do_POST(self) -> None:
                if not self._check_auth_and_host():
                    return
                path = urllib.parse.urlparse(self.path).path
                if path != f"/api/v1/sessions/{daemon.session_id}/commands":
                    self._send_json(404, {"error": "not found"})
                    return
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}
                with daemon._lock:
                    status, payload = daemon._execute_command_locked(body)
                self._send_json(status, payload)

            def _write_chunk(self, text: str) -> None:
                data = text.encode("utf-8")
                self.wfile.write(f"{len(data):x}\r\n".encode("ascii") + data + b"\r\n")
                self.wfile.flush()

            def _handle_sse(self) -> None:
                sub = _SseSubscriber(daemon.session_id, "1")
                with daemon._lock:
                    daemon._subscribers.append(sub)
                    daemon.sse_connect_count += 1
                    snap = {
                        "version": 1,
                        "session_id": daemon.session_id,
                        "conversation_id": "1",
                        "seq": daemon._seq,
                        "before_entry_id": None,
                        "has_more": False,
                        "entries": list(daemon._entries[-50:]),
                        "docs": json.loads(json.dumps(daemon._docs)),
                    }
                    daemon._cond.notify_all()

                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Transfer-Encoding", "chunked")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True

                try:
                    self._write_chunk(
                        f"id: {snap['seq']}\nevent: snapshot\ndata: {json.dumps(snap, separators=(',', ':'))}\n\n"
                    )
                    while not daemon._stop_event.is_set() and not sub.closed.is_set():
                        try:
                            item = sub.queue.get(timeout=0.5)
                        except queue.Empty:
                            self._write_chunk(": keepalive\n\n")
                            continue
                        if item is None:
                            break
                        ev_name, ev_id, data_json = item
                        prefix = f"id: {ev_id}\n" if ev_id is not None else ""
                        self._write_chunk(f"{prefix}event: {ev_name}\ndata: {data_json}\n\n")
                except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                    if getattr(exc, "errno", None) not in (errno.EPIPE, errno.ECONNRESET, errno.EBADF, None):
                        pass
                finally:
                    sub.close()
                    with daemon._lock:
                        daemon._subscribers = [s for s in daemon._subscribers if s is not sub]
                        daemon._cond.notify_all()

        return Handler
