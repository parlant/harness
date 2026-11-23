"""Minimal disposable fake H daemon (HTTP/1.1 + chunked SSE) for PTY tests."""

from __future__ import annotations

import bisect
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
        self.entries_requests: list[dict[str, Any]] = []
        self.sse_connect_count = 0
        self.catalog_sse_connect_count = 0
        self.created_sessions: list[dict[str, Any]] = []

        self._seq = 1
        self._catalog_seq = 1
        self._next_entry_id = 1
        self._next_sub_id = 1
        self._next_conv_id = 2
        self._snapshot_limit = 50
        self._entries: list[dict[str, Any]] = []
        self._conversations: dict[str, dict[str, Any]] = {
            "1": {"id": "1", "parent": None, "owner": "ownerless"}
        }
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
        self._extra_sessions: dict[str, dict[str, Any]] = {}
        self._extra_entries: dict[str, list[dict[str, Any]]] = {}
        self._extra_docs: dict[str, dict[str, Any]] = {}
        self._extra_seq: dict[str, int] = {}
        self._primary_created_at = int(time.time())
        self._primary_title = "Demo Session"
        self._primary_attention: str | None = None
        self._primary_activity_kind: str | None = None
        self._primary_activity_label: str | None = None
        self._primary_needs_attention: bool | None = None
        self._primary_archived = False
        self._primary_loaded = True
        self._primary_cwd_exists: bool | None = None
        self._primary_status = "ok"

        self.triage_requests: list[dict[str, Any]] = []
        self.stop_requests: list[dict[str, Any]] = []
        self.archive_requests: list[dict[str, Any]] = []
        self.fork_requests: list[dict[str, Any]] = []

        self._next_chunks: list[str] = ["Fake response"]
        self._next_gate: threading.Event | None = None
        self._next_gate_timeout: float | None = 10.0

        self._subscribers: list[_SseSubscriber] = []
        self._catalog_subscribers: list[_SseSubscriber] = []
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
            for sub in list(self._catalog_subscribers):
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

    def arm_gated_stream(
        self, *, chunks: list[str], gate_timeout: float | None = 10.0
    ) -> threading.Event:
        gate = threading.Event()
        with self._lock:
            self._next_chunks = list(chunks)
            self._next_gate = gate
            self._next_gate_timeout = gate_timeout
        return gate

    def seed_history(self, count: int, *, snapshot_limit: int = 50) -> None:
        """Seed `count` alternating user/assistant entries for paged-history tests."""
        if count < 0:
            raise ValueError("count must be >= 0")
        if snapshot_limit < 1:
            raise ValueError("snapshot_limit must be >= 1")
        now = int(time.time())
        entries: list[dict[str, Any]] = []
        for idx in range(1, count + 1):
            if idx % 2 == 1:
                kind = "user"
                text = (
                    f"User turn {idx}: inspect module_{idx % 40}.rs and verify "
                    f"cursor paging and concurrent stream rendering."
                )
            else:
                kind = "assistant"
                text = (
                    f"## Analysis {idx}\n\n"
                    f"Reviewed module_{idx % 40}.rs with **inline** notes and enough prose to "
                    f"wrap across terminal columns during scrolling and paging.\n\n"
                    f"- Verified invariant A for entry {idx}\n"
                    f"- Verified invariant B for entry {idx}\n\n"
                    f"```rust\n"
                    f"fn entry_{idx}(x: usize) -> usize {{ x.saturating_add(1) }}\n"
                    f"```"
                )
            entries.append(
                {
                    "id": str(idx),
                    "conversation_id": "1",
                    "seq": idx,
                    "kind": kind,
                    "data": {"content": [{"type": "text", "text": text}]},
                    "created_at": now,
                }
            )
        with self._lock:
            self._entries = entries
            self._conversations = {"1": {"id": "1", "parent": None, "owner": "ownerless"}}
            self._next_conv_id = 2
            self._snapshot_limit = snapshot_limit
            self._next_entry_id = count + 1
            self._seq = max(1, count)
            self._cond.notify_all()

    def _visible_entries_for_conv_locked(
        self, sid: str, cid: str
    ) -> list[dict[str, Any]]:
        all_entries = (
            self._entries
            if not sid or sid == self.session_id
            else self._extra_entries.get(sid, [])
        )
        if sid and sid != self.session_id:
            return list(all_entries)
        conv = self._conversations.get(cid)
        if conv is None:
            return []
        chain: list[tuple[str, int | None]] = []
        cur_cid: str | None = cid
        cap_entry_id: int | None = None
        seen: set[str] = set()
        while cur_cid is not None and cur_cid not in seen:
            seen.add(cur_cid)
            c = self._conversations.get(cur_cid)
            if c is None:
                break
            chain.append((cur_cid, cap_entry_id))
            parent = c.get("parent")
            if isinstance(parent, dict):
                cur_cid = str(parent["conversation_id"])
                cap_entry_id = int(parent["at"])
            else:
                cur_cid = None
                cap_entry_id = None
        chain.reverse()
        visible: list[dict[str, Any]] = []
        for seg_cid, cap in chain:
            for e in all_entries:
                if str(e.get("conversation_id", "1")) != seg_cid:
                    continue
                if cap is not None and int(e["id"]) > cap:
                    continue
                visible.append(e)
        visible.sort(key=lambda e: int(e["id"]))
        return visible

    def _build_session_tree_locked(self, sid: str, session_wire: dict[str, Any]) -> dict[str, Any]:
        all_entries = (
            self._entries
            if sid == self.session_id
            else self._extra_entries.get(sid, [])
        )
        convs_map = (
            self._conversations
            if sid == self.session_id
            else {"1": {"id": "1", "parent": None, "owner": "ownerless"}}
        )
        by_cid: dict[str, list[dict[str, Any]]] = {}
        for e in sorted(all_entries, key=lambda x: int(x["id"])):
            by_cid.setdefault(str(e.get("conversation_id", "1")), []).append(e)

        parent_by_id: dict[str, str | None] = {}
        wired_convs: list[dict[str, Any]] = []
        for cid in sorted(convs_map.keys(), key=lambda c: int(c) if c.isdigit() else 0):
            conv = convs_map[cid]
            own = by_cid.get(cid, [])
            parent = conv.get("parent")
            prev_id = str(parent["at"]) if isinstance(parent, dict) else None
            for e in own:
                eid = str(e["id"])
                parent_by_id[eid] = prev_id
                prev_id = eid
            leaf_id = str(own[-1]["id"]) if own else (str(parent["at"]) if isinstance(parent, dict) else None)
            wired_convs.append(
                {
                    "id": cid,
                    "parent": parent,
                    "owner": conv.get("owner", "ownerless"),
                    "leaf_entry_id": leaf_id,
                }
            )

        nodes: list[dict[str, Any]] = []
        for e in sorted(all_entries, key=lambda x: int(x["id"])):
            eid = str(e["id"])
            kind = str(e.get("kind", "unknown"))
            data = e.get("data") if isinstance(e.get("data"), dict) else {}
            if kind == "user_shell":
                prefix = "!" if data.get("include_in_context", True) else "!!"
                preview = f"{prefix}{data.get('command', '')}".strip()
                has_text = bool(data.get("command"))
                tool_name = None
                aborted = bool(data.get("cancelled", False))
                is_error = bool(data.get("is_error", False))
            elif kind == "tool_result":
                tool_name = data.get("tool_name") or data.get("name")
                preview = f"[{tool_name or 'tool'}]"
                has_text = False
                aborted = False
                is_error = bool(data.get("is_error", False))
            else:
                text = extract_content_text(data.get("content")).replace("\n", " ").strip()
                preview = text[:200]
                has_text = bool(preview)
                tool_name = None
                aborted = bool(data.get("aborted", False))
                is_error = bool(data.get("is_error", False))
            nodes.append(
                {
                    "id": eid,
                    "parent_id": parent_by_id.get(eid),
                    "conversation_id": str(e.get("conversation_id", "1")),
                    "kind": kind,
                    "preview": preview,
                    "has_text": has_text,
                    "tool_name": tool_name,
                    "aborted": aborted,
                    "is_error": is_error,
                    "error": is_error,
                    "created_at": e.get("created_at"),
                }
            )

        return {
            "session": session_wire,
            "conversations": wired_convs,
            "nodes": nodes,
            "truncated": False,
        }

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

    def wait_for_catalog_sse_connect(self, *, min_count: int = 1, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        with self._lock:
            while not self._stop_event.is_set():
                if self.catalog_sse_connect_count >= min_count and self._catalog_subscribers:
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timed out waiting for catalog SSE connect")
                self._cond.wait(timeout=remaining)

    def add_session(
        self,
        session_id: str,
        *,
        cwd: str,
        env_id: str = "host",
        title: str | None = None,
        attention: str = "idle",
        activity_kind: str | None = None,
        activity_label: str | None = None,
        queued_count: int = 0,
        status: str = "ok",
        needs_attention: bool | None = None,
        archived: bool | None = None,
        loaded: bool | None = None,
        cwd_exists: bool | None = None,
        created_at: int | None = None,
        entries: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        now = int(time.time())
        created = created_at if created_at is not None else now
        resolved_cwd = os.path.abspath(cwd) if env_id == "host" else cwd
        eff_archived = bool(archived) or status == "archived"
        eff_attention = (
            "quarantined"
            if status == "quarantined"
            else ("archived" if eff_archived else attention)
        )
        eff_needs_attention = (
            False
            if eff_archived
            else (
                needs_attention
                if needs_attention is not None
                else (eff_attention not in ("running", "sleeping", "archived"))
            )
        )
        eff_loaded = loaded if loaded is not None else (not eff_archived)
        eff_cwd_exists = (
            cwd_exists
            if cwd_exists is not None
            else (os.path.isdir(resolved_cwd) if env_id == "host" else True)
        )
        wire = {
            "session_id": session_id,
            "title": title,
            "env_id": env_id,
            "harness_id": "coding",
            "cwd": resolved_cwd,
            "root_conversation_id": "1",
            "created_at": created,
            "updated_at": now,
            "active": eff_attention in ("running", "sleeping"),
            "attention": eff_attention,
            "activity_kind": activity_kind,
            "activity_label": activity_label,
            "queued_count": queued_count,
            "next_wake_at": None,
            "status": status,
            "needs_attention": eff_needs_attention,
            "archived": eff_archived,
            "loaded": eff_loaded,
            "cwd_exists": eff_cwd_exists,
        }
        with self._lock:
            if session_id == self.session_id:
                self._primary_title = title or self._primary_title
                self._primary_attention = wire["attention"]
                self._primary_activity_kind = activity_kind
                self._primary_activity_label = activity_label
                self._active = wire["active"]
                self._primary_created_at = created
                self._primary_status = status
                self._primary_needs_attention = eff_needs_attention
                self._primary_archived = eff_archived
                self._primary_loaded = eff_loaded
                self._primary_cwd_exists = cwd_exists
                if entries is not None:
                    self._entries = list(entries)
                self._broadcast_catalog_upsert_locked(self._wire_session())
                return self._wire_session()
            self._extra_sessions[session_id] = wire
            self._extra_entries[session_id] = list(entries or [])
            self._extra_docs[session_id] = {
                "live": {},
                "inbox": [],
                "agent": {"model": self.model_id, "thinking": "medium"},
                "usage": {"input_tokens": 0, "output_tokens": 0, "cost": 0.0},
            }
            self._extra_seq[session_id] = max(1, len(self._extra_entries[session_id]))
            self._broadcast_catalog_upsert_locked(dict(wire))
            return dict(wire)

    def update_session_attention(
        self,
        session_id: str,
        *,
        attention: str,
        activity_kind: str | None = None,
        activity_label: str | None = None,
        queued_count: int | None = None,
        needs_attention: bool | None = None,
    ) -> None:
        with self._lock:
            eff_na = (
                needs_attention
                if needs_attention is not None
                else (attention not in ("running", "sleeping", "archived"))
            )
            if session_id == self.session_id:
                self._primary_attention = attention
                self._primary_activity_kind = activity_kind
                self._primary_activity_label = activity_label
                self._active = attention in ("running", "sleeping")
                self._primary_needs_attention = False if self._primary_archived else eff_na
                self._broadcast_catalog_upsert_locked(self._wire_session())
                return
            sess = self._extra_sessions.get(session_id)
            if sess is None:
                raise KeyError(f"unknown session {session_id}")
            sess["attention"] = attention
            sess["active"] = attention in ("running", "sleeping")
            sess["activity_kind"] = activity_kind
            sess["activity_label"] = activity_label
            sess["needs_attention"] = False if sess.get("archived") else eff_na
            if queued_count is not None:
                sess["queued_count"] = queued_count
            sess["updated_at"] = int(time.time())
            self._broadcast_catalog_upsert_locked(dict(sess))

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
        attention = self._primary_attention or ("running" if self._active else "idle")
        activity_kind = self._primary_activity_kind
        if activity_kind is None and attention == "running":
            activity_kind = "generation"
        eff_archived = self._primary_archived or self._primary_status == "archived"
        eff_attention = (
            "quarantined"
            if self._primary_status == "quarantined"
            else ("archived" if eff_archived else attention)
        )
        eff_needs_attention = (
            False
            if eff_archived
            else (
                self._primary_needs_attention
                if self._primary_needs_attention is not None
                else (attention not in ("running", "sleeping", "archived"))
            )
        )
        eff_cwd_exists = (
            self._primary_cwd_exists
            if self._primary_cwd_exists is not None
            else os.path.isdir(self.cwd)
        )
        return {
            "session_id": self.session_id,
            "title": self._primary_title,
            "env_id": "host",
            "harness_id": "coding",
            "cwd": self.cwd,
            "root_conversation_id": "1",
            "created_at": self._primary_created_at,
            "updated_at": now,
            "active": self._active,
            "attention": eff_attention,
            "activity_kind": activity_kind,
            "activity_label": self._primary_activity_label,
            "queued_count": len(self._inbox),
            "next_wake_at": None,
            "status": self._primary_status,
            "needs_attention": eff_needs_attention,
            "archived": eff_archived,
            "loaded": self._primary_loaded,
            "cwd_exists": eff_cwd_exists,
        }

    def _all_wire_sessions_locked(self) -> list[dict[str, Any]]:
        out = [self._wire_session()]
        for sess in self._extra_sessions.values():
            out.append(dict(sess))
        return out

    def _broadcast_catalog_upsert_locked(self, session_wire: dict[str, Any]) -> None:
        self._catalog_seq += 1
        self._catalog_subscribers = [s for s in self._catalog_subscribers if not s.closed.is_set()]
        payload = {
            "version": 1,
            "seq": self._catalog_seq,
            "type": "upsert",
            "session": session_wire,
        }
        for sub in self._catalog_subscribers:
            sub.push("catalog", str(self._catalog_seq), payload)
        self._cond.notify_all()

    def _broadcast_locked(
        self, event_name: str, event_id: str | None, payload: dict[str, Any]
    ) -> None:
        self._subscribers = [s for s in self._subscribers if not s.closed.is_set()]
        target_sid = payload.get("session_id")
        for sub in self._subscribers:
            if target_sid is None or sub.sid == target_sid:
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
        gate_timeout = self._next_gate_timeout
        self._next_chunks = [f"Reply: {prompt_text}"]
        self._next_gate = None
        self._next_gate_timeout = 10.0
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
        self._primary_attention = "running"
        self._primary_activity_kind = "generation"
        self._primary_activity_label = None
        self._primary_needs_attention = False
        self._broadcast_catalog_upsert_locked(self._wire_session())
        t = threading.Thread(
            target=self._run_turn_worker,
            args=(prompt_text, chunks, gate, gate_timeout),
            daemon=True,
        )
        self._turn_threads.append(t)
        t.start()
        return seq

    def _run_turn_worker(
        self,
        prompt_text: str,
        chunks: list[str],
        gate: threading.Event | None,
        gate_timeout: float | None,
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
                if gate_timeout is None:
                    while not self._stop_event.is_set() and not self._aborted and self._active:
                        if gate.wait(timeout=0.25):
                            break
                else:
                    gate.wait(timeout=gate_timeout)

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
                self._primary_attention = "idle"
                self._primary_activity_kind = None
                self._primary_activity_label = None
                self._primary_needs_attention = True
                self._broadcast_catalog_upsert_locked(self._wire_session())
                self._cond.notify_all()

    def _run_user_shell_worker(self, shell_cmd: str, include_ctx: bool) -> None:
        time.sleep(0.02)
        with self._lock:
            if self._stop_event.is_set() or not self._active or self._aborted:
                return
            entry = self._next_entry_locked(
                "user_shell",
                {
                    "command": shell_cmd,
                    "output": f"out:{shell_cmd}",
                    "exit_code": 0,
                    "cancelled": False,
                    "truncated": False,
                    "skipped_bytes": 0,
                    "full_output_path": None,
                    "include_in_context": include_ctx,
                    "is_error": False,
                    "diagnostic": None,
                    "duration_ms": 5,
                },
            )
            self._docs["live"] = {}
            self._commit_locked(
                appended_entries=[entry],
                doc_ops={"live": [["replace", {}]]},
            )
            self._active = False
            self._cond.notify_all()

    def _execute_command_locked(self, raw: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        req_id = raw.get("request_id")
        command = raw.get("command")
        cid_raw = raw.get("conversation_id")
        args = raw.get("args") or {}
        cid_str = str(cid_raw) if isinstance(cid_raw, int) else ""
        if (
            raw.get("version") != 1
            or not isinstance(req_id, str)
            or cid_str not in self._conversations
        ):
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

        if command == "user_shell":
            shell_cmd = args.get("command")
            include_ctx = args.get("include_in_context")
            expected_seq = args.get("expected_seq")
            if (
                not isinstance(shell_cmd, str)
                or not shell_cmd.strip()
                or not isinstance(include_ctx, bool)
                or not isinstance(expected_seq, int)
                or expected_seq < 0
            ):
                return 422, {"error": "invalid user_shell args"}
            if expected_seq != self._seq:
                return 409, {"error": "expected_seq mismatch"}
            if self._active:
                return 409, {"error": "conversation_busy"}

            sub_id = f"sub-{self._next_sub_id}"
            self._next_sub_id += 1
            self._active = True
            self._aborted = False
            live_doc = {
                "user_shell": {
                    "task_id": sub_id,
                    "command": shell_cmd,
                    "include_in_context": include_ctx,
                    "status": "running",
                    "output": "",
                }
            }
            self._docs["live"] = live_doc
            seq = self._commit_locked(doc_ops={"live": [["replace", live_doc]]})
            t = threading.Thread(
                target=self._run_user_shell_worker,
                args=(shell_cmd, include_ctx),
                daemon=True,
            )
            self._turn_threads.append(t)
            t.start()
            self._cond.notify_all()
            return 200, {
                "version": 1,
                "request_id": req_id,
                "seq": seq,
                "submission_id": sub_id,
                "status": "placed",
            }

        if command == "fork":
            at_entry_id = args.get("at_entry_id")
            if not isinstance(at_entry_id, int) or at_entry_id <= 0:
                return 422, {"error": "invalid at_entry_id"}
            visible = self._visible_entries_for_conv_locked(self.session_id, cid_str)
            if not any(int(e["id"]) == at_entry_id for e in visible):
                return 422, {"error": "entry not visible in conversation"}
            new_cid = str(self._next_conv_id)
            self._next_conv_id += 1
            self._conversations[new_cid] = {
                "id": new_cid,
                "parent": {"conversation_id": cid_str, "at": str(at_entry_id)},
                "owner": "ownerless",
            }
            self._seq += 1
            self._cond.notify_all()
            return 200, {
                "version": 1,
                "request_id": req_id,
                "seq": self._seq,
                "conversation_id": new_cid,
                "status": "forked",
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
                parsed = urllib.parse.urlparse(self.path)
                path = parsed.path
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
                if path == "/api/v1/sessions/events":
                    self._handle_catalog_sse()
                    return
                if path == "/api/v1/sessions":
                    with daemon._lock:
                        self._send_json(200, {"sessions": daemon._all_wire_sessions_locked()})
                    return
                if path.startswith("/api/v1/sessions/"):
                    rest = path[len("/api/v1/sessions/") :]
                    parts = rest.split("/")
                    sid = urllib.parse.unquote(parts[0])
                    with daemon._lock:
                        if sid == daemon.session_id:
                            session_wire = daemon._wire_session()
                        elif sid in daemon._extra_sessions:
                            session_wire = dict(daemon._extra_sessions[sid])
                        else:
                            session_wire = None
                    if session_wire is None:
                        self._send_json(404, {"error": "not found"})
                        return
                    if len(parts) == 1:
                        with daemon._lock:
                            convs = (
                                [
                                    dict(daemon._conversations[c])
                                    for c in sorted(
                                        daemon._conversations.keys(),
                                        key=lambda x: int(x) if x.isdigit() else 0,
                                    )
                                ]
                                if sid == daemon.session_id
                                else [{"id": "1", "parent": None, "owner": "ownerless"}]
                            )
                        self._send_json(
                            200,
                            {
                                "session": session_wire,
                                "conversations": convs,
                                "tasks": [],
                            },
                        )
                        return
                    if len(parts) == 2 and parts[1] == "tree":
                        with daemon._lock:
                            payload = daemon._build_session_tree_locked(sid, session_wire)
                        self._send_json(200, payload)
                        return
                    if len(parts) == 4 and parts[1] == "conversations":
                        cid = urllib.parse.unquote(parts[2])
                        with daemon._lock:
                            valid_cid = (
                                cid in daemon._conversations
                                if sid == daemon.session_id
                                else cid == "1"
                            )
                        if not valid_cid:
                            self._send_json(404, {"error": "conversation not found"})
                            return
                        if parts[3] == "entries":
                            self._handle_entries(parsed.query, sid=sid, cid=cid)
                            return
                        if parts[3] == "events":
                            self._handle_sse(sid=sid, cid=cid)
                            return
                self._send_json(404, {"error": "not found"})

            def _handle_entries(self, query: str, *, sid: str = "", cid: str = "1") -> None:
                qs = urllib.parse.parse_qs(query, keep_blank_values=False)
                order = qs.get("order", ["desc"])[0]
                if order not in ("asc", "desc"):
                    self._send_json(422, {"error": "invalid order"})
                    return
                cursor_raw = qs.get("cursor", [None])[0]
                cursor_int: int | None = None
                if cursor_raw is not None:
                    try:
                        cursor_int = int(cursor_raw)
                    except ValueError:
                        self._send_json(422, {"error": "invalid cursor"})
                        return
                limit_raw = qs.get("limit", ["50"])[0]
                try:
                    limit = max(1, min(500, int(limit_raw)))
                except ValueError:
                    self._send_json(422, {"error": "invalid limit"})
                    return

                with daemon._lock:
                    entries = daemon._visible_entries_for_conv_locked(sid, cid)
                    n = len(entries)
                    if order == "desc":
                        end = (
                            bisect.bisect_left(entries, cursor_int, key=lambda e: int(e["id"]))
                            if cursor_int is not None
                            else n
                        )
                        start = max(0, end - limit)
                        items = list(reversed(entries[start:end]))
                        has_rest = start > 0
                    else:
                        start = (
                            bisect.bisect_right(entries, cursor_int, key=lambda e: int(e["id"]))
                            if cursor_int is not None
                            else 0
                        )
                        end = min(n, start + limit)
                        items = list(entries[start:end])
                        has_rest = end < n
                    next_cursor = items[-1]["id"] if (has_rest and items) else None
                    daemon.entries_requests.append(
                        {
                            "order": order,
                            "cursor": cursor_raw,
                            "limit": limit,
                            "returned": len(items),
                            "next_cursor": next_cursor,
                        }
                    )
                self._send_json(200, {"items": items, "next_cursor": next_cursor})

            def do_POST(self) -> None:
                if not self._check_auth_and_host():
                    return
                path = urllib.parse.urlparse(self.path).path
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}
                if path == "/api/v1/sessions":
                    cwd = body.get("cwd") or daemon.cwd
                    env_id = body.get("env_id") or "host"
                    sid = body.get("session_id") or f"sess-{secrets.token_hex(4)}"
                    title = body.get("title")
                    wire = daemon.add_session(
                        sid,
                        cwd=cwd,
                        env_id=env_id,
                        title=title,
                        attention="idle",
                    )
                    with daemon._lock:
                        daemon.created_sessions.append(wire)
                    self._send_json(200, {"session": wire, "seq": 1})
                    return
                if path.startswith("/api/v1/sessions/"):
                    rest = path[len("/api/v1/sessions/") :]
                    parts = rest.split("/")
                    if len(parts) == 2:
                        sid = urllib.parse.unquote(parts[0])
                        action = parts[1]
                        if action == "triage":
                            self._handle_triage(sid, body)
                            return
                        if action == "stop":
                            self._handle_stop(sid, body)
                            return
                        if action == "archive":
                            self._handle_archive(sid, body)
                            return
                        if action == "fork":
                            self._handle_fork(sid, body)
                            return
                        if action == "commands":
                            self._handle_commands(sid, body)
                            return
                self._send_json(404, {"error": "not found"})

            def _handle_triage(self, sid: str, body: dict[str, Any]) -> None:
                na = body.get("needs_attention")
                if not isinstance(na, bool):
                    self._send_json(422, {"error": "needs_attention must be a boolean"})
                    return
                with daemon._lock:
                    if sid == daemon.session_id:
                        if daemon._primary_status == "archived":
                            self._send_json(409, {"error": "session is archived"})
                            return
                        daemon._primary_needs_attention = False if daemon._primary_archived else na
                        wire = daemon._wire_session()
                    elif sid in daemon._extra_sessions:
                        sess = daemon._extra_sessions[sid]
                        if sess.get("status") == "archived":
                            self._send_json(409, {"error": "session is archived"})
                            return
                        sess["needs_attention"] = False if sess.get("archived") else na
                        sess["updated_at"] = int(time.time())
                        wire = dict(sess)
                    else:
                        self._send_json(404, {"error": "session not found"})
                        return
                    daemon.triage_requests.append({"session_id": sid, "needs_attention": na})
                    daemon._broadcast_catalog_upsert_locked(wire)
                self._send_json(200, {"session": wire})

            def _handle_stop(self, sid: str, body: dict[str, Any]) -> None:
                with daemon._lock:
                    if sid == daemon.session_id:
                        if daemon._primary_status == "archived":
                            self._send_json(409, {"error": "session is archived"})
                            return
                        daemon._aborted = True
                        daemon._active = False
                        if daemon._active_gate is not None:
                            daemon._active_gate.set()
                        daemon._docs["live"] = {}
                        daemon._primary_attention = "idle"
                        daemon._primary_activity_kind = None
                        daemon._primary_activity_label = None
                        daemon._primary_needs_attention = not daemon._primary_archived
                        wire = daemon._wire_session()
                    elif sid in daemon._extra_sessions:
                        sess = daemon._extra_sessions[sid]
                        if sess.get("status") == "archived":
                            self._send_json(409, {"error": "session is archived"})
                            return
                        sess["active"] = False
                        sess["attention"] = "idle"
                        sess["activity_kind"] = None
                        sess["activity_label"] = None
                        sess["needs_attention"] = not bool(sess.get("archived"))
                        sess["updated_at"] = int(time.time())
                        wire = dict(sess)
                    else:
                        self._send_json(404, {"error": "session not found"})
                        return
                    daemon.stop_requests.append({"session_id": sid, "reason": body.get("reason")})
                    daemon._broadcast_catalog_upsert_locked(wire)
                self._send_json(200, {"session": wire})

            def _handle_archive(self, sid: str, body: dict[str, Any]) -> None:
                archived = body.get("archived", True)
                stop = bool(body.get("stop", body.get("force", False)))
                if not isinstance(archived, bool):
                    self._send_json(422, {"error": "archived must be a boolean"})
                    return
                with daemon._lock:
                    if sid == daemon.session_id:
                        busy = daemon._active
                        if archived and busy and not stop:
                            self._send_json(409, {"error": "session_busy"})
                            return
                        if archived:
                            if busy:
                                daemon._aborted = True
                                daemon._active = False
                                if daemon._active_gate is not None:
                                    daemon._active_gate.set()
                            daemon._primary_archived = True
                            daemon._primary_needs_attention = False
                            daemon._primary_loaded = False
                            daemon._primary_attention = "idle"
                            daemon._primary_activity_kind = None
                            daemon._primary_activity_label = None
                        else:
                            daemon._primary_archived = False
                            daemon._primary_needs_attention = True
                        wire = daemon._wire_session()
                    elif sid in daemon._extra_sessions:
                        sess = daemon._extra_sessions[sid]
                        busy = bool(sess.get("active"))
                        if archived and busy and not stop:
                            self._send_json(409, {"error": "session_busy"})
                            return
                        if archived:
                            sess["active"] = False
                            if sess.get("status") != "quarantined":
                                sess["attention"] = "archived"
                            sess["activity_kind"] = None
                            sess["activity_label"] = None
                            sess["archived"] = True
                            sess["needs_attention"] = False
                            sess["loaded"] = False
                        else:
                            if sess.get("status") == "archived":
                                self._send_json(409, {"error": "session is archived"})
                                return
                            sess["archived"] = False
                            if sess.get("status") != "quarantined":
                                sess["attention"] = "idle"
                            sess["needs_attention"] = True
                        sess["updated_at"] = int(time.time())
                        wire = dict(sess)
                    else:
                        self._send_json(404, {"error": "session not found"})
                        return
                    daemon.archive_requests.append(
                        {"session_id": sid, "archived": archived, "stop": stop}
                    )
                    daemon._broadcast_catalog_upsert_locked(wire)
                self._send_json(200, {"session": wire})

            def _handle_fork(self, sid: str, body: dict[str, Any]) -> None:
                cwd = body.get("cwd")
                if not isinstance(cwd, str) or not cwd.startswith("/"):
                    self._send_json(422, {"error": "cwd must be an absolute path"})
                    return
                if not os.path.isdir(cwd):
                    self._send_json(422, {"error": "workspace directory does not exist"})
                    return
                with daemon._lock:
                    if sid == daemon.session_id:
                        src_title = daemon._primary_title
                        src_entries = json.loads(json.dumps(daemon._entries))
                        src_env = "host"
                    elif sid in daemon._extra_sessions:
                        src = daemon._extra_sessions[sid]
                        src_title = src.get("title")
                        src_entries = json.loads(json.dumps(daemon._extra_entries.get(sid, [])))
                        src_env = src.get("env_id") or "host"
                    else:
                        self._send_json(404, {"error": "not found"})
                        return
                    new_sid = body.get("session_id") or f"fork-{secrets.token_hex(4)}"
                    env_id = body.get("env_id") or src_env
                    title = body["title"] if "title" in body else src_title
                    daemon.fork_requests.append(
                        {"source_session_id": sid, "new_session_id": new_sid, "cwd": cwd}
                    )
                wire = daemon.add_session(
                    new_sid,
                    cwd=cwd,
                    env_id=env_id,
                    title=title,
                    attention="idle",
                    needs_attention=True,
                    archived=False,
                    loaded=True,
                    cwd_exists=True,
                    entries=src_entries,
                )
                self._send_json(200, {"session": wire, "seq": max(1, len(src_entries))})

            def _handle_commands(self, sid: str, body: dict[str, Any]) -> None:
                with daemon._lock:
                    if sid == daemon.session_id:
                        if daemon._primary_status == "archived":
                            self._send_json(409, {"error": "session is archived"})
                            return
                        wire = daemon._wire_session()
                        if not wire.get("cwd_exists", True) and body.get("command") in (
                            "submit",
                            "fork_and_submit",
                            "user_shell",
                            "compact",
                        ):
                            self._send_json(409, {"error": "cwd_missing"})
                            return
                        if daemon._primary_archived:
                            daemon._primary_archived = False
                            daemon._primary_loaded = True
                            daemon._primary_needs_attention = True
                            daemon._broadcast_catalog_upsert_locked(daemon._wire_session())
                        status, payload = daemon._execute_command_locked(body)
                    elif sid in daemon._extra_sessions:
                        sess = daemon._extra_sessions[sid]
                        if sess.get("status") == "archived":
                            self._send_json(409, {"error": "session is archived"})
                            return
                        if not sess.get("cwd_exists", True) and body.get("command") in (
                            "submit",
                            "fork_and_submit",
                            "user_shell",
                            "compact",
                        ):
                            self._send_json(409, {"error": "cwd_missing"})
                            return
                        if sess.get("archived"):
                            sess["archived"] = False
                            sess["loaded"] = True
                            sess["attention"] = "idle"
                            sess["needs_attention"] = True
                            sess["updated_at"] = int(time.time())
                            daemon._broadcast_catalog_upsert_locked(dict(sess))
                        # Minimal submit handler for extra/forked sessions in PTY tests
                        req_id = body.get("request_id", "r")
                        cmd = body.get("command")
                        args = body.get("args") or {}
                        if cmd == "submit" and args.get("type") == "input":
                            text = extract_content_text(args.get("content"))
                            entries = daemon._extra_entries.setdefault(sid, [])
                            seq = daemon._extra_seq.get(sid, 1) + 1
                            daemon._extra_seq[sid] = seq
                            next_id = len(entries) + 1
                            user_entry = {
                                "id": str(next_id),
                                "conversation_id": "1",
                                "seq": seq,
                                "kind": "user",
                                "data": {"content": [{"type": "text", "text": text}]},
                                "created_at": int(time.time()),
                            }
                            asst_entry = {
                                "id": str(next_id + 1),
                                "conversation_id": "1",
                                "seq": seq + 1,
                                "kind": "assistant",
                                "data": {"content": [{"type": "text", "text": f"Forked reply: {text}"}]},
                                "created_at": int(time.time()),
                            }
                            entries.extend([user_entry, asst_entry])
                            daemon._extra_seq[sid] = seq + 1
                            daemon._broadcast_locked(
                                "commit",
                                str(seq + 1),
                                {
                                    "version": 1,
                                    "session_id": sid,
                                    "conversation_id": "1",
                                    "prev_seq": seq - 1,
                                    "seq": seq + 1,
                                    "appended_entries": [user_entry, asst_entry],
                                    "doc_ops": {"live": [["replace", {}]]},
                                },
                            )
                            status, payload = 200, {
                                "version": 1,
                                "request_id": req_id,
                                "seq": seq + 1,
                                "submission_id": f"sub-{seq}",
                                "status": "done",
                            }
                        else:
                            status, payload = 422, {"error": f"unsupported command: {cmd}"}
                    else:
                        self._send_json(404, {"error": "not found"})
                        return
                self._send_json(status, payload)

            def _write_chunk(self, text: str) -> None:
                data = text.encode("utf-8")
                self.wfile.write(f"{len(data):x}\r\n".encode("ascii") + data + b"\r\n")
                self.wfile.flush()

            def _handle_catalog_sse(self) -> None:
                sub = _SseSubscriber("_catalog", "0")
                with daemon._lock:
                    daemon._catalog_subscribers.append(sub)
                    daemon.catalog_sse_connect_count += 1
                    snap = {
                        "version": 1,
                        "seq": daemon._catalog_seq,
                        "sessions": daemon._all_wire_sessions_locked(),
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

            def _handle_sse(self, *, sid: str = "", cid: str = "1") -> None:
                target_sid = sid or daemon.session_id
                sub = _SseSubscriber(target_sid, cid)
                with daemon._lock:
                    daemon._subscribers.append(sub)
                    daemon.sse_connect_count += 1
                    if target_sid == daemon.session_id:
                        all_entries = daemon._visible_entries_for_conv_locked(target_sid, cid)
                        seq = daemon._seq
                        docs = daemon._docs
                    else:
                        all_entries = daemon._extra_entries.get(target_sid, [])
                        seq = daemon._extra_seq.get(target_sid, 1)
                        docs = daemon._extra_docs.get(
                            target_sid,
                            {
                                "live": {},
                                "inbox": [],
                                "agent": {"model": daemon.model_id, "thinking": "medium"},
                                "usage": {"input_tokens": 0, "output_tokens": 0, "cost": 0.0},
                            },
                        )
                    snap_entries = list(all_entries[-daemon._snapshot_limit :])
                    has_more = len(all_entries) > len(snap_entries) and len(snap_entries) > 0
                    before_entry_id = snap_entries[0]["id"] if has_more else None
                    snap = {
                        "version": 1,
                        "session_id": target_sid,
                        "conversation_id": cid,
                        "seq": seq,
                        "before_entry_id": before_entry_id,
                        "has_more": has_more,
                        "entries": snap_entries,
                        "docs": json.loads(json.dumps(docs)),
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
