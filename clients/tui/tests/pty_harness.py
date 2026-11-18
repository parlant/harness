"""Unix PTY test harness using only the Python standard library."""

from __future__ import annotations

import errno
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import termios
import threading
import time
from typing import Iterable

_ANSI_CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_ANSI_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
_ANSI_ESC_RE = re.compile(r"\x1b[@-Z\\-_]")


def strip_ansi(text: str) -> str:
    cleaned = _ANSI_OSC_RE.sub("", text)
    cleaned = _ANSI_CSI_RE.sub("", cleaned)
    cleaned = _ANSI_ESC_RE.sub("", cleaned)
    return cleaned


def find_hi_binary(repo_root: str | None = None) -> str | None:
    """Locate the `hi` binary from HI_BIN, build target dirs, or PATH."""
    explicit = os.environ.get("HI_BIN", "").strip()
    if explicit:
        return explicit if os.path.isfile(explicit) and os.access(explicit, os.X_OK) else None

    candidates: list[str] = []
    cargo_target = os.environ.get("CARGO_TARGET_DIR", "").strip()
    if cargo_target:
        candidates.extend(
            [
                os.path.join(cargo_target, "debug", "hi"),
                os.path.join(cargo_target, "release", "hi"),
            ]
        )

    if repo_root:
        candidates.extend(
            [
                os.path.join(repo_root, "clients", "tui", "target", "debug", "hi"),
                os.path.join(repo_root, "clients", "tui", "target", "release", "hi"),
                os.path.join(repo_root, "target", "debug", "hi"),
                os.path.join(repo_root, "target", "release", "hi"),
            ]
        )

    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path

    return shutil.which("hi")


def find_h_binary(repo_root: str | None = None) -> str | None:
    """Locate the existing `h` binary for baseline verification."""
    explicit = os.environ.get("H_BIN", "").strip()
    if explicit:
        return explicit if os.path.isfile(explicit) and os.access(explicit, os.X_OK) else None

    candidates: list[str] = []
    cargo_target = os.environ.get("CARGO_TARGET_DIR", "").strip()
    if cargo_target:
        candidates.extend(
            [
                os.path.join(cargo_target, "debug", "h"),
                os.path.join(cargo_target, "release", "h"),
            ]
        )

    if repo_root:
        candidates.extend(
            [
                os.path.join(repo_root, "clients", "tui", "target", "debug", "h"),
                os.path.join(repo_root, "clients", "tui", "target", "release", "h"),
            ]
        )

    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path

    return shutil.which("h")


class PtySession:
    """Spawns a child command attached to a fresh controlling Unix PTY."""

    def __init__(
        self,
        cmd: list[str],
        *,
        env: dict[str, str] | None = None,
        cwd: str | None = None,
        rows: int = 24,
        cols: int = 80,
    ) -> None:
        self.cmd = list(cmd)
        self.master_fd, slave_fd = pty.openpty()

        # Start with explicit cooked termios baseline so raw/restore checks are deterministic.
        attrs = termios.tcgetattr(slave_fd)
        attrs[0] |= termios.ICRNL
        attrs[1] |= termios.OPOST
        attrs[3] |= termios.ECHO | termios.ICANON | termios.ISIG
        termios.tcsetattr(slave_fd, termios.TCSANOW, attrs)
        self.baseline_lflag = termios.tcgetattr(slave_fd)[3]

        winsz = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)

        child_env = (env or os.environ).copy()
        child_env.setdefault("TERM", "xterm-256color")

        def _setup_ctty() -> None:
            os.setsid()
            fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

        try:
            self.proc = subprocess.Popen(
                self.cmd,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                cwd=cwd,
                env=child_env,
                preexec_fn=_setup_ctty,
                close_fds=True,
            )
        finally:
            os.close(slave_fd)

        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._raw_chunks: list[bytes] = []
        self._master_closed = False
        self._reader_done = False

        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self) -> None:
        try:
            while True:
                with self._lock:
                    if self._master_closed:
                        break
                    fd = self.master_fd
                try:
                    rlist, _, _ = select.select([fd], [], [], 0.05)
                except (OSError, ValueError):
                    break
                if not rlist:
                    continue
                try:
                    data = os.read(fd, 4096)
                except OSError as exc:
                    if exc.errno in (errno.EIO, errno.EBADF):
                        break
                    if exc.errno in (errno.EAGAIN, errno.EINTR):
                        continue
                    break
                if not data:
                    break
                with self._lock:
                    self._raw_chunks.append(data)
                    self._cond.notify_all()
        finally:
            with self._lock:
                self._reader_done = True
                self._cond.notify_all()

    def raw_bytes(self) -> bytes:
        with self._lock:
            return b"".join(self._raw_chunks)

    def raw_text(self) -> str:
        return self.raw_bytes().decode("utf-8", errors="replace")

    def clean_text(self) -> str:
        return strip_ansi(self.raw_text())

    def send_bytes(self, data: bytes) -> None:
        with self._lock:
            if self._master_closed:
                raise RuntimeError("cannot write to closed PTY master")
            fd = self.master_fd
        view = memoryview(data)
        sent = 0
        while sent < len(data):
            n = os.write(fd, view[sent:])
            sent += n

    def send_text(self, text: str) -> None:
        self.send_bytes(text.encode("utf-8"))

    def send_enter(self) -> None:
        self.send_bytes(b"\r")

    def send_alt_enter(self) -> None:
        # Sent as a single write so terminal parsers decode ESC+CR atomically as Alt+Enter.
        self.send_bytes(b"\x1b\r")

    def send_ctrl(self, letter: str) -> None:
        code = ord(letter.lower()) - ord("a") + 1
        if not 1 <= code <= 26:
            raise ValueError(f"invalid ctrl key: {letter!r}")
        self.send_bytes(bytes([code]))

    def send_backspace(self, count: int = 1) -> None:
        self.send_bytes(b"\x7f" * count)

    def send_left(self, count: int = 1) -> None:
        self.send_bytes(b"\x1b[D" * count)

    def resize(self, rows: int, cols: int) -> None:
        with self._lock:
            if self._master_closed:
                return
            fd = self.master_fd
        winsz = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, winsz)
        if self.proc.poll() is None:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGWINCH)
            except ProcessLookupError:
                pass

    def lflag(self) -> int:
        with self._lock:
            if self._master_closed:
                raise RuntimeError("PTY master closed")
            fd = self.master_fd
        return termios.tcgetattr(fd)[3]

    def is_raw_mode(self) -> bool:
        flags = self.lflag()
        return not (flags & termios.ICANON) and not (flags & termios.ECHO)

    def is_cooked_mode(self) -> bool:
        flags = self.lflag()
        return bool(flags & termios.ICANON) and bool(flags & termios.ECHO)

    def wait_for_raw_mode(self, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.is_raw_mode():
                return
            if self.proc.poll() is not None:
                raise AssertionError(
                    f"process exited ({self.proc.returncode}) before entering raw mode; output={self.clean_text()!r}"
                )
            time.sleep(0.02)
        raise TimeoutError(f"timed out waiting for raw mode; lflag={self.lflag():#x}")

    def wait_for_output(self, needles: str | Iterable[str], *, timeout: float = 5.0, clean: bool = True) -> str:
        targets = [needles] if isinstance(needles, str) else list(needles)
        deadline = time.monotonic() + timeout
        with self._lock:
            while True:
                haystack = strip_ansi(b"".join(self._raw_chunks).decode("utf-8", errors="replace")) if clean else b"".join(self._raw_chunks).decode("utf-8", errors="replace")
                if any(t in haystack for t in targets):
                    return haystack
                if self._reader_done:
                    raise TimeoutError(
                        f"PTY closed before seeing {targets!r}; output={haystack!r}"
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"timed out waiting for {targets!r}; output={haystack!r}"
                    )
                self._cond.wait(timeout=remaining)

    def close_master_hangup(self) -> None:
        with self._lock:
            if not self._master_closed:
                self._master_closed = True
                os.close(self.master_fd)
                self._cond.notify_all()

    def wait(self, timeout: float = 5.0) -> int:
        return self.proc.wait(timeout=timeout)

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=1.5)
        self.close_master_hangup()
        self._reader.join(timeout=1.0)

    def __enter__(self) -> "PtySession":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.close()
