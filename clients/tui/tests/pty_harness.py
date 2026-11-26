"""Unix PTY test harness and minimal VT/ANSI normalized screen (stdlib only)."""

from __future__ import annotations

import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import threading
import time
from typing import Iterable

_ANSI_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
_ANSI_APC_RE = re.compile(r"\x1b_[^\x1b]*\x1b\\")
_ANSI_CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_ANSI_ESC_RE = re.compile(r"\x1b[@-Z\\-_]")


def strip_ansi(text: str) -> str:
    cleaned = _ANSI_OSC_RE.sub("", text)
    cleaned = _ANSI_APC_RE.sub("", cleaned)
    cleaned = _ANSI_CSI_RE.sub("", cleaned)
    cleaned = _ANSI_ESC_RE.sub("", cleaned)
    return cleaned


class VirtualScreen:
    """Normalized 2D VT/ANSI screen buffer for Ratatui differential output."""

    def __init__(self, rows: int = 24, cols: int = 80) -> None:
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self._main = [[" "] * self.cols for _ in range(self.rows)]
        self._alt = [[" "] * self.cols for _ in range(self.rows)]
        self._on_alt = False
        self.row = 0
        self.col = 0
        self._buf = ""

    def _grid(self) -> list[list[str]]:
        return self._alt if self._on_alt else self._main

    def resize(self, rows: int, cols: int) -> None:
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self._main = [[" "] * self.cols for _ in range(self.rows)]
        self._alt = [[" "] * self.cols for _ in range(self.rows)]
        self.row = min(self.row, self.rows - 1)
        self.col = min(self.col, self.cols - 1)

    def feed(self, text: str) -> None:
        data = self._buf + text
        self._buf = ""
        i = 0
        n = len(data)
        while i < n:
            ch = data[i]
            if ch == "\x1b":
                if i + 1 >= n:
                    self._buf = data[i:]
                    break
                nxt = data[i + 1]
                if nxt == "[":
                    end = self._find_csi_end(data, i + 2)
                    if end is None:
                        self._buf = data[i:]
                        break
                    self._handle_csi(data[i + 2 : end], data[end])
                    i = end + 1
                    continue
                if nxt == "]":
                    end = self._find_osc_end(data, i + 2)
                    if end is None:
                        self._buf = data[i:]
                        break
                    i = end
                    continue
                if nxt == "_":
                    end = self._find_osc_end(data, i + 2)
                    if end is None:
                        self._buf = data[i:]
                        break
                    i = end
                    continue
                i += 2
                continue
            if ch == "\r":
                self.col = 0
            elif ch == "\n":
                if self.row + 1 < self.rows:
                    self.row += 1
                else:
                    grid = self._grid()
                    grid.pop(0)
                    grid.append([" "] * self.cols)
            elif ch == "\b":
                self.col = max(0, self.col - 1)
            elif ch == "\t":
                self.col = min(self.cols - 1, ((self.col // 8) + 1) * 8)
            elif ord(ch) >= 32 and ord(ch) != 127:
                grid = self._grid()
                if self.col >= self.cols:
                    self.col = self.cols - 1
                grid[self.row][self.col] = ch
                if self.col + 1 < self.cols:
                    self.col += 1
            i += 1

    @staticmethod
    def _find_csi_end(data: str, start: int) -> int | None:
        for idx in range(start, len(data)):
            o = ord(data[idx])
            if 0x40 <= o <= 0x7E:
                return idx
        return None

    @staticmethod
    def _find_osc_end(data: str, start: int) -> int | None:
        idx = start
        while idx < len(data):
            if data[idx] == "\x07":
                return idx + 1
            if data[idx] == "\x1b" and idx + 1 < len(data) and data[idx + 1] == "\\":
                return idx + 2
            idx += 1
        return None

    def _parse_params(self, raw: str, default: int = 1) -> list[int]:
        if not raw:
            return [default]
        return [int(p) if p.isdigit() else default for p in raw.split(";")]

    def _handle_csi(self, params: str, final: str) -> None:
        if params.startswith("?"):
            codes = params[1:].split(";")
            if "1049" in codes:
                if final == "h":
                    self._on_alt = True
                    self._alt = [[" "] * self.cols for _ in range(self.rows)]
                    self.row = 0
                    self.col = 0
                elif final == "l":
                    self._on_alt = False
            return

        if final in ("H", "f"):
            parts = params.split(";") if params else []
            r = int(parts[0]) if len(parts) >= 1 and parts[0].isdigit() else 1
            c = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 1
            self.row = max(0, min(self.rows - 1, r - 1))
            self.col = max(0, min(self.cols - 1, c - 1))
        elif final == "A":
            self.row = max(0, self.row - self._parse_params(params)[0])
        elif final == "B":
            self.row = min(self.rows - 1, self.row + self._parse_params(params)[0])
        elif final == "C":
            self.col = min(self.cols - 1, self.col + self._parse_params(params)[0])
        elif final == "D":
            self.col = max(0, self.col - self._parse_params(params)[0])
        elif final == "G":
            self.col = max(0, min(self.cols - 1, self._parse_params(params)[0] - 1))
        elif final == "d":
            self.row = max(0, min(self.rows - 1, self._parse_params(params)[0] - 1))
        elif final == "J":
            mode = self._parse_params(params, 0)[0]
            grid = self._grid()
            if mode == 2:
                for r in range(self.rows):
                    grid[r] = [" "] * self.cols
            elif mode == 0:
                for c in range(self.col, self.cols):
                    grid[self.row][c] = " "
                for r in range(self.row + 1, self.rows):
                    grid[r] = [" "] * self.cols
            elif mode == 1:
                for r in range(self.row):
                    grid[r] = [" "] * self.cols
                for c in range(self.col + 1):
                    grid[self.row][c] = " "
        elif final == "K":
            mode = self._parse_params(params, 0)[0]
            grid = self._grid()
            if mode == 0:
                for c in range(self.col, self.cols):
                    grid[self.row][c] = " "
            elif mode == 1:
                for c in range(self.col + 1):
                    grid[self.row][c] = " "
            elif mode == 2:
                grid[self.row] = [" "] * self.cols

    def text(self) -> str:
        return "\n".join("".join(row).rstrip() for row in self._grid())


def _find_repo_binary(name: str, env_var: str, repo_root: str | None) -> str | None:
    """Locate a project-built binary from explicit env var or Cargo target dirs (never PATH)."""
    explicit = os.environ.get(env_var, "").strip()
    if explicit:
        return explicit if os.path.isfile(explicit) and os.access(explicit, os.X_OK) else None

    candidates: list[str] = []
    cargo_target = os.environ.get("CARGO_TARGET_DIR", "").strip()
    if cargo_target:
        candidates.extend(
            [
                os.path.join(cargo_target, "debug", name),
                os.path.join(cargo_target, "release", name),
            ]
        )

    if repo_root:
        candidates.extend(
            [
                os.path.join(repo_root, "clients", "tui", "target", "debug", name),
                os.path.join(repo_root, "clients", "tui", "target", "release", name),
                os.path.join(repo_root, "target", "debug", name),
                os.path.join(repo_root, "target", "release", name),
            ]
        )

    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path

    return None


def find_hi_binary(repo_root: str | None = None) -> str | None:
    return _find_repo_binary("hi", "HI_BIN", repo_root)


class PtySession:
    """Spawns a child command as session leader attached to a fresh controlling Unix PTY."""

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

        attrs = termios.tcgetattr(slave_fd)
        attrs[0] |= termios.ICRNL
        attrs[1] |= termios.OPOST
        attrs[3] |= termios.ECHO | termios.ICANON | termios.ISIG
        termios.tcsetattr(slave_fd, termios.TCSANOW, attrs)

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
        self._screen = VirtualScreen(rows, cols)
        self._wake_r, self._wake_w = os.pipe()
        self._stop_reader = False
        self._master_closed = False
        self._reader_done = False

        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self) -> None:
        try:
            while True:
                with self._lock:
                    if self._stop_reader or self._master_closed:
                        break
                    fd = self.master_fd
                    wake_r = self._wake_r
                try:
                    rlist, _, _ = select.select([fd, wake_r], [], [])
                except (OSError, ValueError):
                    break
                if wake_r in rlist:
                    break
                if fd not in rlist:
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
                    self._screen.feed(data.decode("utf-8", errors="replace"))
                    self._cond.notify_all()
        finally:
            with self._lock:
                self._reader_done = True
                self._cond.notify_all()

    def _halt_reader(self) -> None:
        with self._lock:
            self._stop_reader = True
            wake_w = self._wake_w
        if wake_w is not None:
            try:
                os.write(wake_w, b"x")
            except OSError:
                pass
        self._reader.join(timeout=1.5)
        with self._lock:
            for attr in ("_wake_r", "_wake_w"):
                fd = getattr(self, attr)
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    setattr(self, attr, None)

    def raw_bytes(self) -> bytes:
        with self._lock:
            return b"".join(self._raw_chunks)

    def raw_text(self) -> str:
        return self.raw_bytes().decode("utf-8", errors="replace")

    def screen_text(self) -> str:
        with self._lock:
            return self._screen.text()

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
            sent += os.write(fd, view[sent:])

    def send_text(self, text: str) -> None:
        self.send_bytes(text.encode("utf-8"))

    def send_enter(self) -> None:
        self.send_bytes(b"\r")

    def send_alt_enter(self) -> None:
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
            self._screen.resize(rows, cols)
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
                    f"process exited ({self.proc.returncode}) before raw mode; screen={self.screen_text()!r}"
                )
            time.sleep(0.02)
        raise TimeoutError(f"timed out waiting for raw mode; lflag={self.lflag():#x}")

    def wait_for_output(self, needles: str | Iterable[str], *, timeout: float = 5.0) -> str:
        """Wait until any needle appears on the normalized virtual screen."""
        targets = [needles] if isinstance(needles, str) else list(needles)
        deadline = time.monotonic() + timeout
        with self._lock:
            while True:
                screen = self._screen.text()
                if any(t in screen for t in targets):
                    return screen
                if self._reader_done:
                    raise TimeoutError(
                        f"PTY closed before seeing {targets!r}; screen={screen!r}"
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"timed out waiting for {targets!r}; screen={screen!r}"
                    )
                self._cond.wait(timeout=remaining)

    def close_master_hangup(self) -> None:
        """Stop reader thread cleanly so no fd/select holds master, then close master_fd."""
        self._halt_reader()
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

    def __enter__(self) -> "PtySession":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.close()
