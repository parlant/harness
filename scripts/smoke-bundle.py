#!/usr/bin/env python3
"""Exercise a relocated release with no build tools, on a disposable store."""

import html
import http.cookiejar
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
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
        erl_flags = "+S 2:2"
        extra_erl_flags = os.environ.get("H_SMOKE_ERL_FLAGS", "").strip()
        if extra_erl_flags:
            erl_flags = f"{erl_flags} {extra_erl_flags}"
        env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "H_DATA_DIR": str(data), "ERL_FLAGS": erl_flags, "H_WEB_PORT": "0"}
        hi = bundle / "bin/hi"
        launcher = bundle / "bin/h-daemon"
        manifest = data / "daemon.json"
        accounts = data / "accounts.json"
        extensions = data / "extensions.json"
        network = data / "network.json"
        compatible = data / "openai-compatible.json"
        router_catalog = Path(__file__).resolve().parents[1] / "examples/providers/openai-compatible.json"
        router_model = "example-router:vendor/Example-Vision"
        addresses = ["127.0.0.1"]
        second_ip = os.environ.get("H_SMOKE_BIND_ADDRESS") or ("127.0.0.2" if sys.platform == "linux" else None)
        if second_ip:
            addresses.append(second_ip)
        http_client = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def api(path, body=None, base=None):
            url = (base or json.loads(manifest.read_text())["http_url"]) + "/api/v1/" + path
            token = (data / "auth.token").read_text().strip()
            request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            with http_client.open(request, timeout=5) as response:
                return json.load(response)

        def run(*args, check=True):
            return subprocess.run(args, check=check, env=env, cwd=root, capture_output=True, text=True, timeout=30)

        assert "Usage:" in run(launcher, "--help").stdout
        assert run(launcher, "--invalid", check=False).returncode == 2
        assert "not running" in run(hi, "daemon", "status", check=False).stderr
        # Crypto and the native trust store must actually load off the bundled runtime.
        run(bundle / "bin/harness", "eval", 'false = Node.alive?(); <<_::256>> = :crypto.hash(:sha256, "bundle"); [_ | _] = :public_key.cacerts_get()')

        def reject(url, status, headers=None, body=None):
            try:
                http_client.open(urllib.request.Request(url, data=body, headers=headers or {}), timeout=5)
            except urllib.error.HTTPError as err:
                assert err.code == status, (url, err.code, status)
            else:
                raise AssertionError(f"Expected HTTP {status} from {url}")

        def check_web(ip):
            boot = (root / "boot.log").read_text()
            web = re.findall(rf"H web listening at (http://{re.escape(ip)}:\d+)/inbox", boot)[-1]
            reject(web + "/login", 421, {"Host": "unconfigured.invalid:4200"})
            browser = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
            with browser.open(web + "/inbox", timeout=5) as response:
                assert response.url == web + "/login"
                login = response.read().decode()
            csrf = html.unescape(re.search(r'name="_csrf_token"\s+value="([^"]+)"', login)[1])
            form = urllib.parse.urlencode({"_csrf_token": csrf, "token": (data / "auth.token").read_text().strip()}).encode()
            with browser.open(web + "/login", form, timeout=5) as response:
                assert "/login" not in response.url
            with browser.open(web + "/inbox", timeout=5) as response:
                assert 'data-session-id="upgrade-smoke"' in response.read().decode()
            with browser.open(web + "/assets/app.js", timeout=5) as response:
                assert response.status == 200

        children = []
        with (root / "boot.log").open("w+") as log:
            def launch(action, *args):
                proc = subprocess.Popen([hi, "daemon", action, "--port", "0", *args], cwd=root, env=env, stdout=log, stderr=log)
                children.append(proc)
                return proc

            def ready(proc):
                deadline = time.monotonic() + 30
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
                assert len(json.loads(manifest.read_text())["http_urls"]) == 1
                check_web("127.0.0.1")
                imports = root / "pi sessions" / "nested"
                imports.mkdir(parents=True)
                source = imports / "fixture.jsonl"
                timestamp = "2026-01-01T00:00:00Z"
                def append_pi(*rows):
                    with source.open("a") as f:
                        for row in rows:
                            f.write(json.dumps({"timestamp": timestamp, **row}) + "\n")
                append_pi({"type": "session", "version": 3, "id": "smoke-pi", "cwd": "/missing/workspace"},
                          {"type": "message", "id": "a", "parentId": None, "message": {"role": "user", "content": "archive prompt"}},
                          {"type": "message", "id": "b", "parentId": "a", "message": {"role": "assistant", "content": "x" * 300_000}})
                def import_pi():
                    return run("/usr/bin/env", "PATH=" + str(bundle / "bin") + ":" + env["PATH"],
                               hi, "import", "--harness", "pi", "--directory", imports.parent).stdout
                assert "Created 1, updated 0" in import_pi()
                assert "unchanged 1" in import_pi()
                append_pi({"type": "message", "id": "c", "parentId": "a", "message": {"role": "user", "content": "forked prompt"}})
                assert "Created 0, updated 1" in import_pi()
                [archive] = api("archives")["archives"]
                archived_sid = archive["session_id"]
                # Both accounts are unsigned; the extension cannot contact OpenAI.
                config = json.dumps({"version": 1, "extensions": [{"path": str(bundle / "extensions/multicodex"), "settings": {"sources": ["personal", "work"]}}]})
                extensions.write_text("malformed")
                refused = run(hi, "daemon", "restart", "--port", "0", check=False)
                assert refused.returncode != 0 and "nothing was stopped" in refused.stderr
                assert old.poll() is None
                extensions.write_text(config)
                network.write_text(json.dumps({"bind_addresses": ["0.0.0.0"]}))
                refused = run(hi, "daemon", "restart", "--port", "0", check=False)
                assert refused.returncode != 0 and "network_config" in refused.stderr
                assert old.poll() is None
                network.write_text(json.dumps({"bind_addresses": addresses}))
                compatible.write_text("malformed")
                refused = run(hi, "daemon", "restart", "--port", "0", check=False)
                assert refused.returncode != 0 and "invalid_openai_compatible_json" in refused.stderr
                assert old.poll() is None
                shutil.copyfile(router_catalog, compatible)

                replacement = launch("restart")
                ready(replacement)
                assert old.wait(timeout=5) == 0
                assert "unchanged 1" in import_pi()
                archive_detail = api(f"sessions/{archived_sid}")
                assert archive_detail["session"]["status"] == "archived"
                [main, fork] = archive_detail["conversations"]
                assert fork["parent"]["conversation_id"] == main["id"]
                fork_entries = api(f"sessions/{archived_sid}/conversations/{fork['id']}/entries")["items"]
                assert [e["data"]["content"] for e in fork_entries] == ["forked prompt", "archive prompt"]
                urls = json.loads(manifest.read_text())["http_urls"]
                assert [urllib.parse.urlsplit(url).hostname for url in urls] == addresses
                for ip, url in zip(addresses, urls):
                    assert api("environments", base=url)["environments"]
                    reject(url + "/api/v1/environments", 401)
                    reject(url + "/api/v1/environments", 421, {"Host": "unconfigured.invalid:4100"})
                    reject(url + "/api/v1/auth/session", 403, {"Origin": "http://unconfigured.invalid:4100"}, b"{}")
                    check_web(ip)
                assert not accounts.exists()
                codex_models = {
                    model["id"]: model for model in api("models")["models"]
                    if model["provider"] == "openai_codex"
                }
                for model, context in [("gpt-6.2-sol", 500_000), ("gpt-6.2-astra", 272_000)]:
                    spec = codex_models[f"openai_codex:{model}"]
                    assert spec["context_window"] == context
                    assert spec["unavailable_reason"] == "Codex sign-in required (/login)"
                api("provider-keys/set", {"provider": "google", "source": "default", "api_key": fixture_key})
                models_by_id = {model["id"]: model for model in api("models")["models"]}
                assert models_by_id["google:gemini-4-neon"]["context_window"] == 1_048_576
                assert models_by_id["google:gemini-4-neon"]["max_output_tokens"] == 65_536
                assert "unavailable_reason" in models_by_id[router_model]
                saved = api("provider-keys/set", {"provider": "example-router", "source": "work", "api_key": fixture_key})
                assert fixture_key not in json.dumps(saved)
                named_models = [model for model in api("models")["models"] if model["provider"] == "example-router"]
                assert len(named_models) == 2 and all("unavailable_reason" not in model for model in named_models)
                for alias in ("personal", "work"):
                    run(hi, "account", "add", alias)

                extensions.write_text("malformed")
                bypass = launch("restart", "--no-extensions")
                ready(bypass)
                assert replacement.wait(timeout=5) == 0
                assert "personal\tnot_signed_in (stock active)" in run(hi, "account", "list").stdout
                profiles = api("provider-keys")
                assert {"active": "work", "provider": "openai", "sources": ["personal", "work"]} in profiles["providers"]
                assert {"active": "work", "provider": "example-router", "sources": ["work"]} in profiles["providers"]
                assert fixture_key not in json.dumps(profiles)
                assert any(model["id"] == router_model for model in api("models")["models"])
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
    print("Bundle passed relocation, no-toolchain boot, authenticated web inbox, host PATH isolation, named provider config and profile persistence, account/session persistence, extension startup/bypass, and guarded restart/shutdown.")


if __name__ == "__main__":
    smoke(Path(sys.argv[1]).resolve())
