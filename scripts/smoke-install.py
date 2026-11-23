#!/usr/bin/env python3
"""Exercise versioned user installation without touching the login service or real HOME."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch


def smoke(bundle):
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="h-install-smoke-", dir="/private/tmp" if sys.platform == "darwin" else "/tmp") as tmp:
        home = Path(tmp)
        data = home / ".local/share/h"
        env = {
            "HOME": tmp,
            "PATH": f"{home}/.bin:/usr/bin:/bin",
            "H_PREFERRED_BIN_DIRS": f"{home}/.nonexistent-pref",
            "ERL_FLAGS": "+S 2:2",
            "H_WEB_PORT": "0",
        }
        hi = home / ".bin/hi"
        backing_bin = home / "bin backing"
        backing_bin.mkdir()
        hi.parent.symlink_to(backing_bin, target_is_directory=True)
        current = home / ".local/opt/harness/current"
        installer = [sys.executable, "-B", root / "scripts/install-bundle.py"]

        def run(*args, check=True):
            return subprocess.run(args, env=env, cwd=tmp, capture_output=True, text=True, timeout=20, check=check)

        missing = run(*installer, check=False)
        assert missing.returncode != 0 and "No bundle at dist/harness" in missing.stderr
        assert not current.parent.exists()
        missing = run(*installer, "--activate", check=False)
        assert missing.returncode == 2 and "requires an installed release ID" in missing.stderr

        # A default build is a link to a tested candidate, not the installed release.
        dist = home / "dist"
        candidate = dist / ".harness-builds/fixture/bundle"
        candidate.parent.mkdir(parents=True)
        (dist / "harness").symlink_to(candidate.relative_to(dist), target_is_directory=True)
        shutil.copytree(bundle, candidate, symlinks=True)

        # Existing unrelated path must not be overwritten.
        hi.write_text("existing")
        refused = run(*installer, bundle, check=False)
        assert refused.returncode != 0 and hi.read_text() == "existing"
        hi.unlink()
        installed = run(*installer)
        assert "to PATH" not in installed.stdout and (backing_bin / "hi").is_symlink()
        initial = current.resolve(strict=True)
        assert hi.resolve(strict=True) == initial / "bin/hi"
        assert (hi.parent / "hi-import").resolve(strict=True) == initial / "bin/hi-import"
        assert "--harness" in run(hi, "import", "--help").stdout
        assert not data.exists()
        run(*installer, bundle)
        second = current.resolve(strict=True)
        assert second != initial and initial.is_dir()
        # The installed copies still work if the checkout build goes away.
        shutil.rmtree(candidate)
        run(*installer, "--activate", initial.name)
        assert current.resolve(strict=True) == initial

        with (home / "boot.log").open("w+") as log:
            daemon = subprocess.Popen([hi, "daemon", "start", "--port", "0"], env=env, cwd=tmp, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 12
                manifest = data / "daemon.json"
                while not manifest.exists() and daemon.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                if not manifest.exists():
                    log.seek(0)
                    raise RuntimeError(log.read())
                assert "Running:" in run(hi, "daemon", "status").stdout
                refused = run(*installer, "--activate", second.name, check=False)
                assert refused.returncode != 0 and "manually started" in refused.stderr
                assert current.resolve(strict=True) == initial and daemon.poll() is None
                run(hi, "daemon", "stop")
                assert daemon.wait(timeout=8) == 0
            finally:
                if daemon.poll() is None:
                    daemon.terminate()
                    try:
                        daemon.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        daemon.kill()
                        daemon.wait(timeout=5)
                lock = data / "lock.json"
                if lock.is_file():
                    Path(json.loads(lock.read_text())["sock_path"]).unlink(missing_ok=True)

        run(*installer, "--activate", second.name)
        assert hi.resolve(strict=True) == second / "bin/hi"
        other_bin = home / "custom bin"
        installed = run(*installer, "--activate", second.name, "--bin-dir", other_bin)
        assert (other_bin / "hi").resolve(strict=True) == second / "bin/hi"
        assert f"Add {other_bin} to PATH" in installed.stdout
        # Exercise service handoff ordering without registering a LaunchAgent.
        spec = importlib.util.spec_from_file_location("h_installer", root / "scripts/install-bundle.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        commands = []
        busy = True
        launchd_error = False
        running = "job = {\n\tactive count = 1\n\tstate = running\n\tpid = 321\n\tlast exit code = 0\n}\n"
        stopped = "job = {\n\tactive count = 0\n\tstate = not running\n\tlast exit code = 0\n}\n"
        states = iter([running])

        def fake_run(argv, _env, timeout=20):
            if argv[0] == "/bin/launchctl":
                action = "print"
            else:
                action = "--check-config" if "--check-config" in argv else argv[-1]
            commands.append(action)
            if action == "status":
                return subprocess.CompletedProcess(argv, 0, "Running: fixture", "")
            if action == "stop":
                assert current.resolve(strict=True) == second
                if busy:
                    return subprocess.CompletedProcess(argv, 1, "", "Daemon is busy")
            if action == "print":
                assert argv == ["/bin/launchctl", "print", f"gui/{os.getuid()}/fake"]
                assert current.resolve(strict=True) == second
                if launchd_error:
                    return subprocess.CompletedProcess(argv, 113, "", "Could not find service")
                state = next(states)
                if isinstance(state, Exception):
                    raise state
                return subprocess.CompletedProcess(argv, 0, state, "")
            if action == "start-service":
                assert current.resolve(strict=True) == initial
                assert commands[-2:] == ["print", "start-service"]
            return subprocess.CompletedProcess(argv, 0, "", "")

        with (
            patch.object(module.Path, "home", return_value=home),
            patch.object(module, "run", side_effect=fake_run),
            patch.object(module, "service_file", return_value=home / "fake.plist"),
            patch.object(module.sys, "argv", ["install", "--activate", initial.name, "--data-dir", str(data), "--bin-dir", str(hi.parent)]),
        ):
            assert module.main() == 1
            assert current.resolve(strict=True) == second
            assert commands == ["--check-config", "status", "check-service", "stop"]
            commands.clear()
            busy = False
            with (
                patch.object(module.time, "monotonic", side_effect=[0, 0, 61]),
                patch.object(module.time, "sleep"),
                patch("sys.stderr") as stderr,
            ):
                assert module.main() == 1
                stderr.write.assert_any_call(
                    f"Installation refused or incomplete: LaunchAgent shutdown did not finish for gui/{os.getuid()}/fake "
                    f"(state=running, active count=1, pid=321, last exit code=0); current bundle was not changed\n"
                    f"Check launchctl and {data / 'h-daemon.log'}. "
                    f"Once the service is stopped, retry with mix h.install --activate {initial.name}."
                )
            assert current.resolve(strict=True) == second
            assert commands == ["--check-config", "status", "check-service", "stop", "print"]
            commands.clear()
            launchd_error = True
            assert module.main() == 1
            assert current.resolve(strict=True) == second
            assert commands == ["--check-config", "status", "check-service", "stop", "print"]
            commands.clear()
            launchd_error = False
            # The API and lock can be gone while launchd still tracks a PID.
            # A PID-less spawn in progress is also not safe to switch through.
            stale_pid = stopped.replace("\tlast exit code", "\tpid = 321\n\tlast exit code")
            scheduled = stopped.replace("not running", "spawn scheduled")
            unrecognized = stopped.replace("not running", "unknown")
            states = iter([
                subprocess.TimeoutExpired("launchctl", 5),
                stale_pid,
                scheduled,
                unrecognized,
                stopped.replace("not running", "exited"),
            ])
            # Clean exit can take longer than the previous 12-second budget.
            with patch.object(module.time, "monotonic", side_effect=[0, 0, 6, 11, 13, 15, 15, 15]), patch.object(module.time, "sleep"):
                assert module.main() == 0
            assert current.resolve(strict=True) == initial
            assert commands == ["--check-config", "status", "check-service", "stop"] + ["print"] * 5 + ["start-service", "status"]

            commands.clear()
            module.switch(current, second)
            states = iter([stopped])
            module.wait_until_stopped(home / "fake.plist", env)
            assert commands == ["print"]

        # Exercise PATH bin_dir cascade (preferred writable dirs win over ~/.bin; ~/.bin only last)
        pref_a = home / "pref-a"
        pref_b = home / "pref-b"
        pref_a.mkdir()
        pref_b.mkdir()
        custom_path_bin = home / "user-bin"
        custom_path_bin.mkdir()
        try:
            assert module.select_bin_dir(
                None,
                home=home,
                path_env=f"{home}/.bin:{pref_b}:{pref_a}:/usr/bin:/bin",
                preferred=(str(pref_a), str(pref_b)),
            ) == pref_a
            os.chmod(pref_a, 0o555)
            assert module.select_bin_dir(
                None,
                home=home,
                path_env=f"{pref_a}:{pref_b}:{home}/.bin:/usr/bin:/bin",
                preferred=(str(pref_a), str(pref_b)),
            ) == pref_b
            os.chmod(pref_b, 0o555)
            assert module.select_bin_dir(
                None,
                home=home,
                path_env=f"{pref_a}:{home}/.bin:{custom_path_bin}:/usr/bin:/bin",
                preferred=(str(pref_a), str(pref_b)),
            ) == custom_path_bin
            assert module.select_bin_dir(
                None,
                home=home,
                path_env="/usr/bin:/bin",
                preferred=(str(pref_a), str(pref_b)),
            ) == (home / ".bin")
        finally:
            os.chmod(pref_a, 0o755)
            os.chmod(pref_b, 0o755)

        # No installer runs launchctl unless service registration was explicit.
        assert not (home / "Library/LaunchAgents").exists()
    print("Install passed default and explicit bundle paths, PATH resolution, copy/activation/rollback, conflict and live-daemon refusal, and simulated guarded service handoff with delayed VM exit and shutdown failures.")


if __name__ == "__main__":
    smoke(Path(sys.argv[1]).resolve(strict=True))
