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
        env = {"HOME": tmp, "PATH": f"{home}/.bin:/usr/bin:/bin", "ERL_FLAGS": "+S 2:2"}
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

        def fake_run(argv, _env, timeout=20):
            action = "--check-config" if "--check-config" in argv else argv[-1]
            commands.append(action)
            if action == "status":
                return subprocess.CompletedProcess(argv, 0, "Running: fixture", "")
            if action == "stop":
                assert current.resolve(strict=True) == second
                if busy:
                    return subprocess.CompletedProcess(argv, 1, "", "Daemon is busy")
            if action == "start-service":
                assert current.resolve(strict=True) == initial
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
            assert module.main() == 0
            assert current.resolve(strict=True) == initial
            assert commands[-3:] == ["stop", "start-service", "status"]

        # No installer runs launchctl unless service registration was explicit.
        assert not (home / "Library/LaunchAgents").exists()
    print("Install passed default and explicit bundle paths, PATH resolution, copy/activation/rollback, conflict and live-daemon refusal, and simulated guarded service handoff.")


if __name__ == "__main__":
    smoke(Path(sys.argv[1]).resolve(strict=True))
