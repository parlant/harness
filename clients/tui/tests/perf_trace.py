"""Reproducible release-binary PTY benchmark for `hi` on 10k-entry paged history
with concurrent streaming across fullscreen and regular modes, compared against
small history.

Usage:
  python3 clients/tui/tests/perf_trace.py --hi-bin /path/to/release/hi
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import asdict, dataclass
from typing import Any

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, "..", "..", ".."))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from fake_daemon import FakeDaemon  # noqa: E402
from pty_harness import PtySession, find_hi_binary  # noqa: E402

PROBE_PREFIX = "!p:"
PROBE_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def read_rss_kib(pid: int) -> int | None:
    """Return resident set size in KiB for `pid` via `ps -o rss=`, or None."""
    try:
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(pid)],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return int(out) if out else None
    except (subprocess.SubprocessError, ValueError):
        return None


def summarize_ms(samples: list[float]) -> dict[str, Any]:
    if not samples:
        return {"count": 0, "min": None, "p50": None, "mean": None, "p95": None, "p99": None, "max": None}
    s = sorted(samples)
    n = len(s)

    def pct(p: float) -> float:
        return round(s[min(n - 1, max(0, math.ceil(p * n) - 1))], 3)

    return {
        "count": n,
        "min": round(s[0], 3),
        "p50": pct(0.50),
        "mean": round(statistics.fmean(s), 3),
        "p95": pct(0.95),
        "p99": pct(0.99),
        "max": round(s[-1], 3),
    }


def summarize_kib(samples: list[int]) -> dict[str, Any]:
    if not samples:
        return {"count": 0, "min": None, "mean": None, "p95": None, "max": None}
    s = sorted(samples)
    n = len(s)
    return {
        "count": n,
        "min": s[0],
        "mean": round(statistics.fmean(s), 1),
        "p95": s[min(n - 1, max(0, math.ceil(0.95 * n) - 1))],
        "max": s[-1],
    }


class _StreamDriver:
    def __init__(self, daemon: FakeDaemon, interval_s: float = 0.012) -> None:
        self._daemon = daemon
        self._interval_s = interval_s
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self.chunks_emitted = 0

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2.0)

    def _run(self) -> None:
        idx = 0
        while not self._stop.wait(self._interval_s):
            idx += 1
            sep = "\n" if idx % 10 == 0 else " "
            self._daemon.emit_ephemeral_chunk(f"tok{idx:04d}{sep}")
            self.chunks_emitted += 1


class _RssSampler:
    def __init__(self, pid: int, interval_s: float = 0.05) -> None:
        self._pid = pid
        self._interval_s = interval_s
        self._lock = threading.Lock()
        self._phase = "startup"
        self._samples: dict[str, list[int]] = {}
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def set_phase(self, phase: str) -> None:
        with self._lock:
            self._phase = phase
        self._record(phase)

    def _record(self, phase: str) -> None:
        rss = read_rss_kib(self._pid)
        if rss is not None:
            with self._lock:
                self._samples.setdefault(phase, []).append(rss)

    def stop(self) -> dict[str, list[int]]:
        self._stop.set()
        self._thread.join(timeout=2.0)
        with self._lock:
            return {k: list(v) for k, v in self._samples.items()}

    def _run(self) -> None:
        while not self._stop.wait(self._interval_s):
            with self._lock:
                phase = self._phase
            self._record(phase)


@dataclass
class RunMetrics:
    label: str
    history_entries: int
    tui_mode: str
    rows: int
    cols: int
    pages_requested: int
    pages_loaded: int
    startup_rss_kib: int | None
    paging_key_ms: dict[str, Any]
    paging_cmd_ms: dict[str, Any]
    paging_scroll_ms: dict[str, Any]
    steady_streaming_key_ms: dict[str, Any]
    steady_idle_key_ms: dict[str, Any]
    rss_kib_by_phase: dict[str, dict[str, Any]]
    stream_chunks_emitted: int
    raw_pty_bytes: int


def _wait_absent(pty: PtySession, needle: str, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    with pty._lock:
        while needle in pty._screen.text():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for {needle!r} to clear")
            pty._cond.wait(timeout=remaining)


def _measure_key_burst(
    pty: PtySession, *, count: int, warmup: int = 0, pause_s: float = 0.0
) -> list[float]:
    assert count + warmup <= len(PROBE_ALPHABET)
    samples: list[float] = []
    pty.send_text(PROBE_PREFIX)
    pty.wait_for_output(PROBE_PREFIX, timeout=5.0)
    typed = PROBE_PREFIX

    for idx in range(warmup + count):
        ch = PROBE_ALPHABET[idx]
        expected = typed + ch
        t0 = time.perf_counter_ns()
        pty.send_bytes(ch.encode("ascii"))
        pty.wait_for_output(expected, timeout=5.0)
        t1 = time.perf_counter_ns()
        typed = expected
        if idx >= warmup:
            samples.append((t1 - t0) / 1_000_000.0)
        if pause_s > 0.0:
            time.sleep(pause_s)

    pty.send_backspace(len(typed))
    _wait_absent(pty, PROBE_PREFIX)
    return samples


def _measure_earlier(pty: PtySession, needle: str) -> float:
    pty.send_text("/earlier")
    pty.wait_for_output("/earlier", timeout=5.0)
    t0 = time.perf_counter_ns()
    pty.send_enter()
    pty.wait_for_output(needle, timeout=10.0)
    return (time.perf_counter_ns() - t0) / 1_000_000.0


def run_benchmark_case(
    *,
    hi_bin: str,
    label: str,
    history_entries: int,
    tui_mode: str,
    rows: int = 30,
    cols: int = 100,
    pages: int = 8,
    keys_per_page: int = 10,
    steady_keys: int = 60,
    key_interval_s: float = 0.015,
    stream_interval_s: float = 0.012,
) -> RunMetrics:
    workdir = tempfile.mkdtemp(prefix=f"hi-perf-{label}-", dir="/tmp")
    try:
        with FakeDaemon(transport="uds", cwd=workdir, session_id="demo") as daemon:
            daemon.seed_history(history_entries, snapshot_limit=50)
            gate = daemon.arm_gated_stream(chunks=["StreamInit "], gate_timeout=None)

            cmd = [hi_bin, "-s", "demo", "--tui-mode", tui_mode]
            with PtySession(cmd, env=daemon.env(), cwd=workdir, rows=rows, cols=cols) as pty:
                daemon.wait_for_sse_connect(timeout=10.0)
                pty.wait_for_raw_mode(timeout=10.0)
                pty.wait_for_output("Ready", timeout=10.0)
                startup_rss = read_rss_kib(pty.proc.pid)

                pty.send_text("bench stream")
                pty.send_enter()
                daemon.wait_for_stream_active(min_ephemerals=1, timeout=10.0)
                pty.wait_for_output("StreamInit", timeout=10.0)

                streamer = _StreamDriver(daemon, interval_s=stream_interval_s)
                rss_sampler = _RssSampler(pty.proc.pid, interval_s=0.05)
                streamer.start()
                rss_sampler.start()

                paging_keys: list[float] = []
                paging_cmds: list[float] = []
                paging_scrolls: list[float] = []
                steady_stream_keys: list[float] = []
                steady_idle_keys: list[float] = []

                try:
                    rss_sampler.set_phase("paging")
                    _measure_key_burst(pty, count=0, warmup=3)
                    has_paged = history_entries > 50

                    for page_idx in range(pages):
                        if has_paged:
                            newest_id = history_entries - 50 * (page_idx + 1)
                            if newest_id >= 1:
                                paging_cmds.append(_measure_earlier(pty, f"#{newest_id}]"))
                        elif page_idx == 0:
                            paging_cmds.append(_measure_earlier(pty, "No earlier history"))
                        else:
                            pty.send_text("/earlier")
                            pty.wait_for_output("/earlier", timeout=5.0)
                            pty.send_enter()
                            time.sleep(0.02)

                        if tui_mode == "fullscreen":
                            t0 = time.perf_counter_ns()
                            pty.send_bytes(b"\x1b[5~")
                            pty.wait_for_output("[↑ ", timeout=5.0)
                            paging_scrolls.append((time.perf_counter_ns() - t0) / 1_000_000.0)
                            pty.send_bytes(b"\x1b[1;5F")
                            _wait_absent(pty, "[↑ ")

                        paging_keys.extend(
                            _measure_key_burst(pty, count=keys_per_page, pause_s=key_interval_s)
                        )

                    rss_sampler.set_phase("steady_streaming")
                    pty.send_text("/latest")
                    pty.wait_for_output("/latest", timeout=5.0)
                    pty.send_enter()
                    pty.wait_for_output("Following live transcript", timeout=10.0)

                    _measure_key_burst(pty, count=0, warmup=5)
                    rem = steady_keys
                    while rem > 0:
                        batch = min(30, rem)
                        steady_stream_keys.extend(
                            _measure_key_burst(pty, count=batch, pause_s=key_interval_s)
                        )
                        rem -= batch

                    streamer.stop()
                    gate.set()
                    daemon.wait_for_turn_idle(timeout=10.0)
                    pty.wait_for_output(f"#{history_entries + 2}]", timeout=10.0)

                    rss_sampler.set_phase("steady_idle")
                    _measure_key_burst(pty, count=0, warmup=5)
                    rem = steady_keys
                    while rem > 0:
                        batch = min(30, rem)
                        steady_idle_keys.extend(
                            _measure_key_burst(pty, count=batch, pause_s=key_interval_s)
                        )
                        rem -= batch

                    rss_raw = rss_sampler.stop()
                finally:
                    streamer.stop()
                    gate.set()
                    rss_sampler.stop()

                pty.send_text("/quit")
                pty.send_enter()
                if pty.wait(timeout=10.0) != 0:
                    raise RuntimeError(f"hi failed: {pty.clean_text()!r}")
                if not pty.is_cooked_mode():
                    raise RuntimeError("hi did not restore cooked mode on /quit")
                if daemon.abort_commands():
                    raise RuntimeError(f"unexpected abort commands: {daemon.abort_commands()!r}")

                raw_bytes = len(pty.raw_bytes())
                pages_loaded = len(daemon.entries_requests)

        return RunMetrics(
            label=label,
            history_entries=history_entries,
            tui_mode=tui_mode,
            rows=rows,
            cols=cols,
            pages_requested=pages,
            pages_loaded=pages_loaded,
            startup_rss_kib=startup_rss,
            paging_key_ms=summarize_ms(paging_keys),
            paging_cmd_ms=summarize_ms(paging_cmds),
            paging_scroll_ms=summarize_ms(paging_scrolls),
            steady_streaming_key_ms=summarize_ms(steady_stream_keys),
            steady_idle_key_ms=summarize_ms(steady_idle_keys),
            rss_kib_by_phase={p: summarize_kib(v) for p, v in rss_raw.items()},
            stream_chunks_emitted=streamer.chunks_emitted,
            raw_pty_bytes=raw_bytes,
        )
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def resolve_hi_bin(explicit: str | None) -> str:
    """Resolve `hi` binary from --hi-bin, HI_BIN, release target dirs, or repo fallback."""
    if explicit:
        if os.path.isfile(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise FileNotFoundError(f"hi binary not executable: {explicit}")
    env_bin = os.environ.get("HI_BIN", "").strip()
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin

    release_candidates: list[str] = []
    cargo_target = os.environ.get("CARGO_TARGET_DIR", "").strip()
    if cargo_target:
        release_candidates.append(os.path.join(cargo_target, "release", "hi"))
    release_candidates.extend(
        [
            os.path.join(REPO_ROOT, "clients", "tui", "target", "release", "hi"),
            os.path.join(REPO_ROOT, "target", "release", "hi"),
        ]
    )
    for path in release_candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path

    found = find_hi_binary(REPO_ROOT)
    if found:
        return found
    raise FileNotFoundError(
        "hi binary not found; pass --hi-bin /path/to/release/hi or set HI_BIN"
    )


def format_report(results: list[RunMetrics], hi_bin: str) -> str:
    lines = [
        f"hi binary: {hi_bin}",
        "label             mode        entries  pages  startup_rss  "
        "paging_p95  page_cmd_p95  scroll_p95  steady_stream_p95  steady_idle_p95  "
        "rss_page_max  rss_stream_max  rss_idle_max  chunks  pty_kib",
    ]
    fmt = lambda v, u="": f"{v}{u}" if v is not None else "n/a"
    for r in results:
        lines.append(
            f"{r.label:<17} {r.tui_mode:<11} {r.history_entries:>7}  "
            f"{r.pages_loaded}/{r.pages_requested:<3}  "
            f"{fmt(r.startup_rss_kib, 'K'):>11}  "
            f"{fmt(r.paging_key_ms['p95'], 'ms'):>10}  "
            f"{fmt(r.paging_cmd_ms['p95'], 'ms'):>12}  "
            f"{fmt(r.paging_scroll_ms['p95'], 'ms'):>10}  "
            f"{fmt(r.steady_streaming_key_ms['p95'], 'ms'):>17}  "
            f"{fmt(r.steady_idle_key_ms['p95'], 'ms'):>15}  "
            f"{fmt(r.rss_kib_by_phase.get('paging', {}).get('max'), 'K'):>12}  "
            f"{fmt(r.rss_kib_by_phase.get('steady_streaming', {}).get('max'), 'K'):>14}  "
            f"{fmt(r.rss_kib_by_phase.get('steady_idle', {}).get('max'), 'K'):>12}  "
            f"{r.stream_chunks_emitted:>6}  {r.raw_pty_bytes / 1024:>7.1f}"
        )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Reproducible release PTY benchmark for hi")
    parser.add_argument("--hi-bin", default=None, help="Path to release hi binary (or set HI_BIN)")
    parser.add_argument("--rows", type=int, default=30)
    parser.add_argument("--cols", type=int, default=100)
    parser.add_argument("--large-entries", type=int, default=10_000)
    parser.add_argument("--small-entries", type=int, default=20)
    parser.add_argument("--pages", type=int, default=8)
    parser.add_argument("--keys-per-page", type=int, default=10)
    parser.add_argument("--steady-keys", type=int, default=60)
    parser.add_argument("--key-interval-ms", type=float, default=15.0)
    parser.add_argument("--stream-interval-ms", type=float, default=12.0)
    parser.add_argument("--json-out", default=None, help="Optional path to write full raw JSON metrics")
    args = parser.parse_args(argv)

    hi_bin = resolve_hi_bin(args.hi_bin)
    results = [
        run_benchmark_case(
            hi_bin=hi_bin,
            label=label,
            history_entries=entries,
            tui_mode=mode,
            rows=args.rows,
            cols=args.cols,
            pages=args.pages,
            keys_per_page=args.keys_per_page,
            steady_keys=args.steady_keys,
            key_interval_s=args.key_interval_ms / 1000.0,
            stream_interval_s=args.stream_interval_ms / 1000.0,
        )
        for label, entries, mode in [
            ("10k-fullscreen", args.large_entries, "fullscreen"),
            ("10k-regular", args.large_entries, "regular"),
            ("small-fullscreen", args.small_entries, "fullscreen"),
            ("small-regular", args.small_entries, "regular"),
        ]
    ]

    print(format_report(results, hi_bin))
    payload = {
        "hi_bin": hi_bin,
        "config": vars(args),
        "results": [asdict(r) for r in results],
    }
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
    else:
        print("\nRAW_JSON:")
        print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
