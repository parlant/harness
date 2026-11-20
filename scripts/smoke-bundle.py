#!/usr/bin/env python3
"""Exercise a relocated release with no build tools, on a disposable store."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request


def smoke(source):
    tmpdir = "/private/tmp" if sys.platform == "darwin" else "/tmp"
    with tempfile.TemporaryDirectory(prefix="h-bundle-smoke-", dir=tmpdir) as tmp:
        root = Path(tmp)
        bundle = root / "moved bundle"
        shutil.copytree(source, bundle)
        data = root / "store"
        data.mkdir(mode=0o700)
        home = root / "home"
        home.mkdir(mode=0o700)
        env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "H_DATA_DIR": str(data), "ERL_FLAGS": "+S 2:2"}
        hi = bundle / "bin/hi"
        launcher = bundle / "bin/h-daemon"
        manifest = data / "daemon.json"
        accounts = data / "accounts.json"
        extensions = data / "extensions.json"

        def api(path, body=None):
            url = json.loads(manifest.read_text())["http_url"] + "/api/v1/" + path
            token = (data / "auth.token").read_text().strip()
            request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.load(response)

        def run(*args, check=True):
            return subprocess.run(args, check=check, env=env, cwd=root, capture_output=True, text=True, timeout=10)

        assert "Usage:" in run(launcher, "--help").stdout
        assert run(launcher, "--invalid", check=False).returncode == 2
        assert "not running" in run(hi, "daemon", "status", check=False).stderr
        # Crypto and the native trust store must actually load off the bundled runtime.
        run(bundle / "bin/harness", "eval", 'false = Node.alive?(); <<_::256>> = :crypto.hash(:sha256, "bundle"); [_ | _] = :public_key.cacerts_get()')

        children = []
        with (root / "boot.log").open("w+") as log:
            def launch(action, *args):
                proc = subprocess.Popen([hi, "daemon", action, "--port", "0", *args], cwd=root, env=env, stdout=log, stderr=log)
                children.append(proc)
                return proc

            def ready(proc):
                deadline = time.monotonic() + 12
                while proc.poll() is None and time.monotonic() < deadline:
                    if manifest.is_file() and json.loads(manifest.read_text())["pid"] == proc.pid:
                        assert "Running:" in run(hi, "daemon", "status").stdout
                        return
                    time.sleep(.05)
                log.seek(0)
                raise RuntimeError(log.read())

            try:
                old = launch("start")
                ready(old)
                assert not accounts.exists()
                fixture_key = "fixture-no-network-api-key"
                for alias in ("personal", "work"):
                    saved = api("provider-keys/set", {"provider": "openai", "source": alias, "api_key": fixture_key})
                    assert fixture_key not in json.dumps(saved)
                api("provider-keys/use", {"provider": "openai", "source": "work"})
                assert not list((data / "sessions").glob("*"))
                session = api("sessions", {"cwd": str(root), "session_id": "upgrade-smoke"})
                cid = session["session"]["root_conversation_id"]
                # Display-only write: exercise storage without dispatching to any provider.
                api("sessions/upgrade-smoke/commands", {
                    "version": 1, "request_id": "before-restart", "conversation_id": cid, "command": "submit",
                    "args": {"type": "write", "content": "survives planned restart"},
                })
                # Both accounts are unsigned; the extension cannot contact OpenAI.
                config = json.dumps({"version": 1, "extensions": [{"path": str(bundle / "extensions/multicodex"), "settings": {"sources": ["personal", "work"]}}]})
                extensions.write_text("malformed")
                refused = run(hi, "daemon", "restart", "--port", "0", check=False)
                assert refused.returncode != 0 and "nothing was stopped" in refused.stderr
                assert old.poll() is None
                extensions.write_text(config)

                replacement = launch("restart")
                ready(replacement)
                assert old.wait(timeout=5) == 0
                assert not accounts.exists()
                codex_models = {
                    model["id"]: model for model in api("models")["models"]
                    if model["provider"] == "openai_codex"
                }
                for model, context in [("gpt-6.2-sol", 500_000), ("gpt-6.2-astra", 272_000)]:
                    spec = codex_models[f"openai_codex:{model}"]
                    assert spec["context_window"] == context
                    assert spec["unavailable_reason"] == "Codex sign-in required (/login)"
                for alias in ("personal", "work"):
                    run(hi, "account", "add", alias)

                extensions.write_text("malformed")
                bypass = launch("restart", "--no-extensions")
                ready(bypass)
                assert replacement.wait(timeout=5) == 0
                assert "personal\tnot_signed_in (stock active)" in run(hi, "account", "list").stdout
                profiles = api("provider-keys")
                assert {"active": "work", "provider": "openai", "sources": ["personal", "work"]} in profiles["providers"]
                assert fixture_key not in json.dumps(profiles)
                entries = api(f"sessions/upgrade-smoke/conversations/{cid}/entries")["items"]
                assert len(entries) == 1 and "survives planned restart" in json.dumps(entries)
                # Host commands should use the original PATH, not the bundled Erlang toolchain.
                session = api("sessions", {"cwd": str(root), "session_id": "path-smoke"})
                path_cid = session["session"]["root_conversation_id"]
                api("sessions/path-smoke/commands", {
                    "version": 1, "request_id": "host-path", "conversation_id": path_cid,
                    "command": "user_shell", "args": {
                        "command": 'printf "%s" "$PATH"', "include_in_context": False,
                        "expected_seq": session["seq"],
                    },
                })
                deadline = time.monotonic() + 5
                path_entries = []
                while not path_entries and time.monotonic() < deadline:
                    path_entries = api(f"sessions/path-smoke/conversations/{path_cid}/entries")["items"]
                    if not path_entries:
                        time.sleep(.05)
                assert path_entries[0]["data"]["output"] == env["PATH"], path_entries
                run(hi, "daemon", "stop")
                assert bypass.wait(timeout=5) == 0
            finally:
                for proc in reversed(children):
                    if proc.poll() is None:
                        proc.terminate()
                        try:
                            proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                            proc.wait(timeout=5)
                lock = data / "lock.json"
                if lock.is_file():
                    Path(json.loads(lock.read_text())["sock_path"]).unlink(missing_ok=True)

        assert "not running" in run(hi, "daemon", "status", check=False).stderr
        assert extensions.read_text() == "malformed"
    print("Bundle passed relocation, no-toolchain boot, host PATH isolation, account/session persistence, extension startup/bypass, and guarded restart/shutdown.")


if __name__ == "__main__":
    smoke(Path(sys.argv[1]).resolve())
