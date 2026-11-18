#!/usr/bin/env python3
"""Concise isolated release smoke test for h and hi against disposable daemons.

Complements (does not duplicate) `clients/tui/tests/test_hi_pty.py`:
  1. Isolated `cargo install --locked --path clients/tui --root <tmp>` (`h` + `hi`).
  2. Print compatibility (`h -p`, `hi -p`, piped `hi <prompt>`, `TERM=dumb hi <prompt>`).
  3. Start (auto-create), resume (`-c`, `-r`, `--tui-mode regular`), non-aborting detach.
  4. Sentinel `pi` store non-modification and rollback isolation.
  5. Optional (`--with-elixir`) check against disposable `H.serve` + `H.Provider.Fake`.

Never writes to or invokes tests against real user stores or user project directories.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
TUI_DIR = REPO_ROOT / "clients" / "tui"
TESTS_DIR = TUI_DIR / "tests"

if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from fake_daemon import FakeDaemon, extract_content_text  # noqa: E402
from pty_harness import PtySession  # noqa: E402


class SmokeDaemon(FakeDaemon):
    """Extends FakeDaemon with `POST /api/v1/sessions` for unflagged `hi` start."""

    def _make_handler_class(self) -> type:
        base_cls = super()._make_handler_class()
        daemon = self

        class SmokeHandler(base_cls):  # type: ignore[misc,valid-type]
            def do_POST(self) -> None:
                if not self._check_auth_and_host():
                    return
                path = urllib.parse.urlparse(self.path).path
                if path == "/api/v1/sessions":
                    length = int(self.headers.get("Content-Length", "0"))
                    body = (
                        json.loads(self.rfile.read(length).decode("utf-8"))
                        if length > 0
                        else {}
                    )
                    with daemon._lock:
                        requested_sid = body.get("session_id")
                        if isinstance(requested_sid, str) and requested_sid.strip():
                            daemon.session_id = requested_sid.strip()
                        if isinstance(body.get("cwd"), str) and body["cwd"].strip():
                            daemon.cwd = body["cwd"].strip()
                        payload = {"session": daemon._wire_session(), "seq": daemon._seq}
                    self._send_json(200, payload)
                    return
                super().do_POST()

        return SmokeHandler


def snapshot_tree(root: Path) -> dict[str, tuple[int, str]]:
    snap: dict[str, tuple[int, str]] = {}
    if not root.exists():
        return snap
    for path in sorted(root.rglob("*")):
        rel = str(path.relative_to(root))
        if path.is_file():
            snap[rel] = (path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest())
        elif path.is_dir():
            snap[rel + "/"] = (0, "<dir>")
    return snap


def create_sentinel_pi_store(home_dir: Path) -> Path:
    agent_dir = home_dir / ".pi" / "agent"
    sessions_dir = agent_dir / "sessions"
    skills_dir = agent_dir / "skills" / "sentinel-skill"
    sessions_dir.mkdir(parents=True, exist_ok=True)
    skills_dir.mkdir(parents=True, exist_ok=True)

    (agent_dir / "settings.json").write_text(
        json.dumps({"defaultThinkingLevel": "medium", "tuiMode": "fullscreen"}, indent=2) + "\n",
        encoding="utf-8",
    )
    (agent_dir / "auth.json").write_text(
        json.dumps({"sentinel": {"type": "api_key", "key": "sentinel-only"}}) + "\n",
        encoding="utf-8",
    )
    (sessions_dir / "sentinel.jsonl").write_text(
        '{"type":"session","id":"sentinel-1","cwd":"/tmp/sentinel"}\n',
        encoding="utf-8",
    )
    (skills_dir / "SKILL.md").write_text(
        "---\nname: sentinel-skill\ndescription: Sentinel skill fixture.\n---\n",
        encoding="utf-8",
    )
    return agent_dir


def run_cmd(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float = 120.0,
) -> tuple[int, str, str, float]:
    t0 = time.monotonic()
    proc = subprocess.run(
        argv,
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout, proc.stderr, time.monotonic() - t0


def isolated_env(
    daemon_env: dict[str, str],
    iso_home: Path,
    pi_agent_dir: Path,
    *,
    term: str = "xterm-256color",
) -> dict[str, str]:
    env = dict(daemon_env)
    env["HOME"] = str(iso_home)
    env["PI_CODING_AGENT_DIR"] = str(pi_agent_dir)
    env["PI_OFFLINE"] = "1"
    env["TERM"] = term
    env.pop("VISUAL", None)
    env.pop("EDITOR", None)
    return env


def test_install(
    install_root: Path,
    target_dir: Path,
    base_env: dict[str, str],
) -> dict[str, Any]:
    env = dict(base_env)
    env["CARGO_TARGET_DIR"] = str(target_dir)
    cmd = [
        "cargo",
        "install",
        "--locked",
        "--path",
        str(TUI_DIR),
        "--root",
        str(install_root),
        "--force",
    ]
    rc, out, err, install_s = run_cmd(cmd, cwd=REPO_ROOT, env=env, timeout=300.0)
    if rc != 0:
        raise RuntimeError(f"cargo install failed (rc={rc}):\n{out}\n{err}")

    h_bin = install_root / "bin" / "h"
    hi_bin = install_root / "bin" / "hi"
    for b in (h_bin, hi_bin):
        if not b.is_file() or not os.access(b, os.X_OK):
            raise RuntimeError(f"missing executable binary after install: {b}")

    results: dict[str, Any] = {
        "install_seconds": round(install_s, 3),
        "h_bytes": h_bin.stat().st_size,
        "hi_bytes": hi_bin.stat().st_size,
    }

    for name, b in (("h", h_bin), ("hi", hi_bin)):
        rc_v, out_v, _, ver_s = run_cmd([str(b), "--version"], cwd=REPO_ROOT, env=env, timeout=10.0)
        if rc_v != 0:
            raise RuntimeError(f"{name} --version failed: rc={rc_v}")
        rc_h, out_h, _, _ = run_cmd([str(b), "--help"], cwd=REPO_ROOT, env=env, timeout=10.0)
        if rc_h != 0 or "--print" not in out_h:
            raise RuntimeError(f"{name} --help failed: rc={rc_h}")
        rc_short_v, _, _, _ = run_cmd([str(b), "-v"], cwd=REPO_ROOT, env=env, timeout=10.0)
        if rc_short_v == 0:
            raise RuntimeError(f"{name} -v unexpectedly succeeded; expected -V only")
        results[f"{name}_version"] = out_v.strip()
        results[f"{name}_version_seconds"] = round(ver_s, 4)

    return results


def test_smoke_lifecycle(
    h_bin: Path,
    hi_bin: Path,
    iso_home: Path,
    pi_agent_dir: Path,
    workdir: Path,
) -> dict[str, Any]:
    # 1. Print compatibility: h -p, hi -p, hi piped, TERM=dumb hi
    with SmokeDaemon(transport="uds", cwd=str(workdir), session_id="print-smoke") as daemon:
        env = isolated_env(daemon.env(), iso_home, pi_agent_dir)

        daemon.arm_auto_stream(chunks=["PrintReplyH"])
        rc, out, err, _ = run_cmd(
            [str(h_bin), "-s", "print-smoke", "-p", "hello via h -p"],
            cwd=workdir,
            env=env,
            timeout=15.0,
        )
        assert rc == 0 and "PrintReplyH" in out, f"h -p failed: rc={rc} out={out!r} err={err!r}"

        daemon.arm_auto_stream(chunks=["PrintReplyHiFlag"])
        with PtySession(
            [str(hi_bin), "-s", "print-smoke", "-p", "hello via hi -p"],
            env=env,
            cwd=str(workdir),
        ) as pty:
            pty.wait_for_output("PrintReplyHiFlag", timeout=10.0)
            assert pty.wait(timeout=10.0) == 0
            assert "\x1b[?1049h" not in pty.raw_text()

        daemon.arm_auto_stream(chunks=["PrintReplyPiped"])
        rc, out, err, _ = run_cmd(
            [str(hi_bin), "-s", "print-smoke", "positional piped"],
            cwd=workdir,
            env=env,
            timeout=15.0,
        )
        assert rc == 0 and "PrintReplyPiped" in out, f"hi piped failed: rc={rc} out={out!r} err={err!r}"

        daemon.arm_auto_stream(chunks=["PrintReplyDumb"])
        dumb_env = isolated_env(daemon.env(), iso_home, pi_agent_dir, term="dumb")
        with PtySession(
            [str(hi_bin), "-s", "print-smoke", "positional dumb"],
            env=dumb_env,
            cwd=str(workdir),
        ) as pty:
            pty.wait_for_output("PrintReplyDumb", timeout=10.0)
            assert pty.wait(timeout=10.0) == 0
            assert "\x1b[?1049h" not in pty.raw_text()

    # 2. Start (auto-create session), resume (-c, -r, --tui-mode regular), detach + reattach
    proj_cwd = workdir / "proj-a"
    proj_cwd.mkdir(parents=True, exist_ok=True)
    with SmokeDaemon(transport="uds", cwd=str(proj_cwd), session_id="seed") as daemon:
        env = isolated_env(daemon.env(), iso_home, pi_agent_dir)

        daemon.arm_auto_stream(chunks=["StartReplyToken"])
        with PtySession([str(hi_bin)], env=env, cwd=str(proj_cwd)) as pty:
            daemon.wait_for_sse_connect(min_count=1, timeout=10.0)
            pty.wait_for_raw_mode(timeout=10.0)
            pty.wait_for_output("Ready", timeout=10.0)
            pty.send_text("smoke start")
            pty.send_enter()
            pty.wait_for_output("StartReplyToken", timeout=10.0)
            pty.send_text("/quit")
            pty.send_enter()
            assert pty.wait(timeout=10.0) == 0 and pty.is_cooked_mode()

        with PtySession([str(hi_bin), "-r"], env=env, cwd=str(proj_cwd)) as pty:
            daemon.wait_for_sse_connect(min_count=2, timeout=10.0)
            pty.wait_for_raw_mode(timeout=10.0)
            pty.wait_for_output("sessions", timeout=10.0)
            pty.send_enter()
            pty.wait_for_output("StartReplyToken", timeout=10.0)
            pty.send_ctrl("d")
            assert pty.wait(timeout=10.0) == 0 and pty.is_cooked_mode()

        daemon.arm_auto_stream(chunks=["RegularModeReply"])
        prev_sse = daemon.sse_connect_count
        with PtySession(
            [str(hi_bin), "-c", "--tui-mode", "regular"], env=env, cwd=str(proj_cwd)
        ) as pty:
            daemon.wait_for_sse_connect(min_count=prev_sse + 1, timeout=10.0)
            pty.wait_for_raw_mode(timeout=10.0)
            pty.wait_for_output("StartReplyToken", timeout=10.0)
            pty.send_text("regular prompt")
            pty.send_enter()
            pty.wait_for_output("RegularModeReply", timeout=10.0)
            pty.send_text("/quit")
            pty.send_enter()
            assert pty.wait(timeout=10.0) == 0 and pty.is_cooked_mode()
            assert "\x1b[?1049h" not in pty.raw_text()

        gate = daemon.arm_gated_stream(chunks=["DetachAlpha ", "DetachBeta"])
        with PtySession([str(hi_bin), "-c"], env=env, cwd=str(proj_cwd)) as pty:
            pty.wait_for_raw_mode(timeout=10.0)
            pty.wait_for_output("Ready", timeout=10.0)
            pty.send_text("detach test")
            pty.send_enter()
            daemon.wait_for_stream_active(min_ephemerals=1, timeout=10.0)
            pty.wait_for_output("DetachAlpha", timeout=10.0)
            pty.send_text("/quit")
            pty.send_enter()
            assert pty.wait(timeout=10.0) == 0 and pty.is_cooked_mode()

        assert daemon.abort_commands() == [], "detach must not send abort"
        gate.set()
        daemon.wait_for_turn_idle(timeout=10.0)

        with PtySession([str(hi_bin), "-c"], env=env, cwd=str(proj_cwd)) as pty:
            pty.wait_for_raw_mode(timeout=10.0)
            pty.wait_for_output("DetachAlpha DetachBeta", timeout=10.0)
            pty.send_ctrl("d")
            assert pty.wait(timeout=10.0) == 0 and pty.is_cooked_mode()

        assistant_texts = [
            extract_content_text(e["data"].get("content"))
            for e in daemon.conversation_entries()
            if e.get("kind") == "assistant"
        ]
        assert "DetachAlpha DetachBeta" in assistant_texts

    return {"print_compat": "ok", "start_resume_detach_regular": "ok"}


def test_real_elixir_daemon(
    h_bin: Path,
    hi_bin: Path,
    iso_home: Path,
    pi_agent_dir: Path,
    tmpdir: Path,
) -> dict[str, Any]:
    real_home = Path.home()
    data_dir = tmpdir / "elx-data"
    data_dir.mkdir(parents=True, exist_ok=True)
    workdir = tmpdir / "elx-cwd"
    workdir.mkdir(parents=True, exist_ok=True)

    mix_env = dict(os.environ)
    mix_env["HOME"] = str(iso_home)
    mix_env.setdefault("MIX_HOME", str(real_home / ".mix"))
    mix_env.setdefault("HEX_HOME", str(real_home / ".hex"))
    mix_env.setdefault("MIX_BUILD_PATH", str(tmpdir / "mix-build"))

    if not (REPO_ROOT / "deps").exists() and "MIX_DEPS_PATH" not in mix_env:
        raise RuntimeError(
            "--with-elixir requires deps/ in repo or MIX_DEPS_PATH pointing to fetched deps"
        )

    rc, out, err, _ = run_cmd(["mix", "compile"], cwd=REPO_ROOT, env=mix_env, timeout=180.0)
    if rc != 0:
        raise RuntimeError(f"mix compile failed (rc={rc}):\n{out}\n{err}")

    ex_script = f'''
{{:ok, _}} = Application.ensure_all_started(:harness)
{{:ok, fake}} = H.Provider.Fake.start_link(script: [
  {{:reply, [%{{type: :text_delta, text: "ElixirPrintOK", metadata: %{{}}}}], %{{content: [%{{type: "text", text: "ElixirPrintOK"}}], finish_reason: "stop"}}}},
  {{:reply, [%{{type: :text_delta, text: "ElixirStartOK", metadata: %{{}}}}], %{{content: [%{{type: "text", text: "ElixirStartOK"}}], finish_reason: "stop"}}}},
  {{:reply, [%{{type: :text_delta, text: "ElixirResumeOK", metadata: %{{}}}}], %{{content: [%{{type: "text", text: "ElixirResumeOK"}}], finish_reason: "stop"}}}}
])
{{:ok, info}} = H.serve(data_dir: "{data_dir}", port: 0, provider: H.Provider.Fake, provider_config: %{{server: fake}})
IO.puts("READY " <> JSON.encode!(info))
receive do
  :never -> :ok
end
'''
    proc = subprocess.Popen(
        ["mix", "run", "--no-compile", "--no-halt", "-e", ex_script],
        cwd=str(REPO_ROOT),
        env=mix_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        assert proc.stdout is not None
        ready = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            line = proc.stdout.readline()
            if not line:
                break
            if line.startswith("READY "):
                ready = json.loads(line[6:].strip())
                break
        if not ready:
            raise RuntimeError("disposable Elixir H daemon failed to start")

        cli_env = {
            **os.environ,
            "HOME": str(iso_home),
            "PI_CODING_AGENT_DIR": str(pi_agent_dir),
            "PI_OFFLINE": "1",
            "TERM": "xterm-256color",
            "H_DATA_DIR": str(data_dir),
        }
        cli_env.pop("H_DAEMON_URL", None)

        rc, out, err, _ = run_cmd(
            [str(h_bin), "-p", "elixir print"], cwd=workdir, env=cli_env, timeout=15.0
        )
        assert rc == 0 and "ElixirPrintOK" in out, f"elixir h -p failed: rc={rc} out={out!r} err={err!r}"

        with PtySession([str(hi_bin)], env=cli_env, cwd=str(workdir)) as pty:
            pty.wait_for_raw_mode(timeout=10.0)
            pty.wait_for_output("Ready", timeout=10.0)
            pty.send_text("elixir start")
            pty.send_enter()
            pty.wait_for_output("ElixirStartOK", timeout=10.0)
            pty.send_text("/quit")
            pty.send_enter()
            assert pty.wait(timeout=10.0) == 0 and pty.is_cooked_mode()

        with PtySession([str(hi_bin), "-c"], env=cli_env, cwd=str(workdir)) as pty:
            pty.wait_for_raw_mode(timeout=10.0)
            pty.wait_for_output("ElixirStartOK", timeout=10.0)
            pty.send_text("elixir resume")
            pty.send_enter()
            pty.wait_for_output("ElixirResumeOK", timeout=10.0)
            pty.send_ctrl("d")
            assert pty.wait(timeout=10.0) == 0 and pty.is_cooked_mode()

        sessions_dir = data_dir / "sessions"
        session_dirs = list(sessions_dir.iterdir()) if sessions_dir.exists() else []
        assert len(session_dirs) >= 2, f"expected persisted sessions in {sessions_dir}"
        return {
            "elixir_daemon": "ok",
            "persisted_sessions": len(session_dirs),
            "api_socket": ready.get("api_socket"),
        }
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def test_rollback_probe(iso_home: Path, pi_agent_dir: Path) -> dict[str, Any]:
    node_bin = shutil.which("node")
    cli_env_path = os.environ.get("PI_CLI_JS")
    cli_path = Path(cli_env_path) if cli_env_path else None
    if not node_bin or not cli_path or not cli_path.is_file():
        return {"pi_rollback_probe": "skipped (set PI_CLI_JS=/path/to/dist/bundle/cli.js to run)"}

    env = {
        **os.environ,
        "HOME": str(iso_home),
        "PI_CODING_AGENT_DIR": str(pi_agent_dir),
        "PI_OFFLINE": "1",
    }
    rc, out, err, dt = run_cmd([node_bin, str(cli_path), "--version"], cwd=iso_home, env=env, timeout=15.0)
    if rc != 0:
        raise RuntimeError(f"pi rollback --version probe failed: rc={rc} err={err!r}")
    return {
        "pi_rollback_probe": "ok",
        "pi_version": out.strip(),
        "pi_version_seconds": round(dt, 4),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Concise isolated release smoke test for h and hi")
    parser.add_argument(
        "--fresh-target",
        action="store_true",
        help="Use a fresh temporary CARGO_TARGET_DIR for cold build timing",
    )
    parser.add_argument(
        "--with-elixir",
        action="store_true",
        help="Also test against disposable Elixir H.serve + H.Provider.Fake",
    )
    parser.add_argument(
        "--keep-tmp",
        action="store_true",
        help="Keep temporary sandbox directory for inspection",
    )
    parser.add_argument(
        "--json-report",
        type=Path,
        help="Optional path to write JSON metrics summary",
    )
    args = parser.parse_args()

    # Keep total path short enough for Unix socket sun_path limits (~104 bytes on macOS).
    tmpdir = Path(tempfile.mkdtemp(prefix="hismk-", dir="/tmp")).resolve()
    try:
        install_root = tmpdir / "inst"
        target_dir = (
            tmpdir / "target"
            if args.fresh_target
            else Path(os.environ.get("CARGO_TARGET_DIR", str(tmpdir / "target")))
        )
        iso_home = tmpdir / "home"
        workdir = tmpdir / "cwd"
        workdir.mkdir(parents=True, exist_ok=True)

        pi_agent_dir = create_sentinel_pi_store(iso_home)
        before_pi = snapshot_tree(iso_home / ".pi")

        report: dict[str, Any] = {"sandbox": str(tmpdir)}
        report["install"] = test_install(install_root, target_dir, dict(os.environ))

        h_bin = install_root / "bin" / "h"
        hi_bin = install_root / "bin" / "hi"

        report["smoke"] = test_smoke_lifecycle(h_bin, hi_bin, iso_home, pi_agent_dir, workdir)

        if args.with_elixir:
            report["elixir"] = test_real_elixir_daemon(
                h_bin, hi_bin, iso_home, pi_agent_dir, tmpdir
            )

        report["rollback"] = test_rollback_probe(iso_home, pi_agent_dir)

        after_pi = snapshot_tree(iso_home / ".pi")
        if before_pi != after_pi:
            raise RuntimeError(f"sentinel pi store changed! before={before_pi} after={after_pi}")
        report["pi_store_unmodified"] = True

        rendered = json.dumps(report, indent=2)
        print(rendered)
        if args.json_report:
            args.json_report.write_text(rendered + "\n", encoding="utf-8")
        return 0
    finally:
        if args.keep_tmp:
            print(f"Kept sandbox: {tmpdir}", file=sys.stderr)
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
