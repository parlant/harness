#!/usr/bin/env python3
"""Offline loopback test suite for scripts/install.sh."""

from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass


def make_bundle_tarball(dest_tar: Path, version: str, target: str, nested: bool = True) -> str:
    with tempfile.TemporaryDirectory(dir="/private/tmp" if sys.platform == "darwin" else "/tmp") as td:
        root = Path(td)
        base = root / (f"harness-v{version}-{target}" if nested else ".")
        (base / "bin").mkdir(parents=True, exist_ok=True)
        (base / "releases").mkdir(parents=True, exist_ok=True)
        hi = base / "bin/hi"
        hi.write_text(f"#!/bin/sh\necho hi-{version}-{target} \"$*\"\n")
        hi.chmod(0o755)
        hi_import = base / "bin/hi-import"
        hi_import.write_text(f"#!/bin/sh\necho hi-import-{version}-{target}\n")
        hi_import.chmod(0o755)
        daemon = base / "bin/h-daemon"
        daemon.write_text(f"#!/bin/sh\necho h-daemon-{version}-{target}\n")
        daemon.chmod(0o755)
        (base / "releases/start_erl.data").write_text("17.1.1 0.1.0\n")

        with tarfile.open(dest_tar, "w:gz") as tf:
            if nested:
                tf.add(base, arcname=base.name)
            else:
                for child in base.iterdir():
                    tf.add(child, arcname=child.name)

    return hashlib.sha256(dest_tar.read_bytes()).hexdigest()


def sign_file(key_path: Path, target_file: Path) -> None:
    subprocess.run(
        ["ssh-keygen", "-q", "-Y", "sign", "-f", str(key_path), "-n", "file", str(target_file)],
        check=True,
    )


def build_release_dir(release_dir: Path, key_path: Path, version: str, targets: list[tuple[str, bool]]) -> dict[str, str]:
    lines = []
    hashes = {}
    for target, nested in targets:
        name = f"harness-v{version}-{target}.tar.gz"
        digest = make_bundle_tarball(release_dir / name, version, target, nested=nested)
        lines.append(f"{digest}  {name}\n")
        hashes[target] = name
    sums = release_dir / "SHA256SUMS"
    sums.write_text("".join(lines))
    sign_file(key_path, sums)
    return hashes


def run_install(script: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/sh", str(script), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "scripts/install.sh"

    # Syntax & conciseness check
    subprocess.run(["/bin/sh", "-n", str(script)], check=True)
    line_count = len(script.read_text().splitlines())
    assert line_count <= 200, f"Expected install.sh <= 200 lines, got {line_count}"

    tmp_root = "/private/tmp" if sys.platform == "darwin" else "/tmp"
    with tempfile.TemporaryDirectory(prefix="h-test-install-sh-", dir=tmp_root) as td:
        td_path = Path(td)
        key_good = td_path / "signer_good"
        key_bad = td_path / "signer_bad"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key_good)], check=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key_bad)], check=True)
        good_pub = " ".join((td_path / "signer_good.pub").read_text().strip().split()[:2])

        srv_dir = td_path / "server"
        v1_dir = srv_dir / "v1"
        v2_dir = srv_dir / "v2"
        corrupt_tar_dir = srv_dir / "corrupt-tar"
        bad_sig_dir = srv_dir / "bad-sig"
        for d in (v1_dir, v2_dir, corrupt_tar_dir, bad_sig_dir):
            d.mkdir(parents=True)

        targets = [
            ("darwin-arm64", True),
            ("linux-arm64", True),
            ("linux-x86_64", False),  # Also test flat archive layout
        ]
        build_release_dir(v1_dir, key_good, "0.1.0", targets)
        build_release_dir(v2_dir, key_good, "0.2.0", targets)

        # Corrupt tarball (valid signed SHA256SUMS, tampered tarball bytes)
        build_release_dir(corrupt_tar_dir, key_good, "0.3.0", [("darwin-arm64", True)])
        (corrupt_tar_dir / "harness-v0.3.0-darwin-arm64.tar.gz").write_bytes(b"corrupted-payload")

        # Tampered signature (signed by wrong key)
        build_release_dir(bad_sig_dir, key_bad, "0.4.0", [("darwin-arm64", True)])

        handler = partial(QuietHandler, directory=str(srv_dir))
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        try:
            base = f"http://127.0.0.1:{port}"
            base_env = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(td_path / "home"),
                "H_SIGNER_PUBKEY": good_pub,
            }
            (td_path / "home").mkdir()

            # 1. Fresh install across all three target triples (darwin/arm64, linux/arm64, linux/x86_64)
            for os_name, arch_name, expected_target in [
                ("Darwin", "arm64", "darwin-arm64"),
                ("Linux", "aarch64", "linux-arm64"),
                ("Linux", "x86_64", "linux-x86_64"),
            ]:
                prefix = td_path / f"prefix-{expected_target}"
                bin_dir = td_path / f"bin-{expected_target}"
                env = {
                    **base_env,
                    "H_RELEASE_URL": f"{base}/v1",
                    "H_OS": os_name,
                    "H_ARCH": arch_name,
                }
                res = run_install(script, env, "--prefix", str(prefix), "--bin-dir", str(bin_dir))
                assert res.returncode == 0, f"{expected_target} failed: {res.stdout}\n{res.stderr}"
                current = prefix / "current"
                assert current.is_symlink()
                assert (bin_dir / "hi").is_symlink()
                assert (bin_dir / "hi-import").is_symlink()
                hi_out = subprocess.run([str(bin_dir / "hi"), "version"], capture_output=True, text=True, check=True)
                assert hi_out.stdout.strip() == f"hi-0.1.0-{expected_target} version"
                imp_out = subprocess.run([str(bin_dir / "hi-import")], capture_output=True, text=True, check=True)
                assert imp_out.stdout.strip() == f"hi-import-0.1.0-{expected_target}"
                assert f"Add {bin_dir} to PATH" in res.stdout

            # 2. Upgrade over existing current symlink retains previous release & switches atomically
            prefix = td_path / "prefix-darwin-arm64"
            bin_dir = td_path / "bin-darwin-arm64"
            first_target = (prefix / "current").resolve(strict=True)
            env_v2 = {
                **base_env,
                "H_RELEASE_URL": f"{base}/v2",
                "H_OS": "Darwin",
                "H_ARCH": "arm64",
            }
            res = run_install(script, env_v2, "--prefix", str(prefix), "--bin-dir", str(bin_dir))
            assert res.returncode == 0, f"upgrade failed: {res.stderr}"
            second_target = (prefix / "current").resolve(strict=True)
            assert second_target != first_target
            assert first_target.is_dir(), "previous release must be retained for rollback"
            assert not any(p.name.startswith(".current.") for p in prefix.iterdir())
            hi_out = subprocess.run([str(bin_dir / "hi")], capture_output=True, text=True, check=True)
            assert hi_out.stdout.strip() == "hi-0.2.0-darwin-arm64"

            # 3. Corrupt checksum rejected; existing current symlink untouched
            env_corrupt = {
                **base_env,
                "H_RELEASE_URL": f"{base}/corrupt-tar",
                "H_OS": "Darwin",
                "H_ARCH": "arm64",
            }
            res = run_install(script, env_corrupt, "--prefix", str(prefix), "--bin-dir", str(bin_dir))
            assert res.returncode != 0
            assert "SHA-256 mismatch" in res.stderr
            assert (prefix / "current").resolve(strict=True) == second_target

            # 4. Wrong signer / tampered signature rejected; nothing installed into fresh prefix
            fresh_prefix = td_path / "prefix-badsig"
            fresh_bin = td_path / "bin-badsig"
            env_badsig = {
                **base_env,
                "H_RELEASE_URL": f"{base}/bad-sig",
                "H_OS": "Darwin",
                "H_ARCH": "arm64",
            }
            res = run_install(script, env_badsig, "--prefix", str(fresh_prefix), "--bin-dir", str(fresh_bin))
            assert res.returncode != 0
            assert "signature verification failed" in res.stderr.lower()
            assert not fresh_prefix.exists()

            # 5. Tampered SHA256SUMS bytes after signing also rejected
            (v1_dir / "SHA256SUMS").write_text((v1_dir / "SHA256SUMS").read_text() + "# tampered\n")
            env_tampered = {
                **base_env,
                "H_RELEASE_URL": f"{base}/v1",
                "H_OS": "Darwin",
                "H_ARCH": "arm64",
            }
            res = run_install(script, env_tampered, "--prefix", str(fresh_prefix), "--bin-dir", str(fresh_bin))
            assert res.returncode != 0
            assert "signature verification failed" in res.stderr.lower()
            assert not fresh_prefix.exists()

            # 6. Refuse to overwrite non-symlink hi file
            conflict_prefix = td_path / "prefix-conflict"
            conflict_bin = td_path / "bin-conflict"
            conflict_bin.mkdir()
            (conflict_bin / "hi").write_text("user script")
            env_conflict = {
                **base_env,
                "H_RELEASE_URL": f"{base}/v2",
                "H_OS": "Darwin",
                "H_ARCH": "arm64",
            }
            res = run_install(script, env_conflict, "--prefix", str(conflict_prefix), "--bin-dir", str(conflict_bin))
            assert res.returncode != 0
            assert "refusing to replace" in res.stderr
            assert (conflict_bin / "hi").read_text() == "user script"

            # 7. Linux --service creates systemd --user unit and calls systemctl
            fake_bin = td_path / "fake-systemctl-bin"
            fake_bin.mkdir()
            systemctl_log = td_path / "systemctl.log"
            fake_systemctl = fake_bin / "systemctl"
            fake_systemctl.write_text(f"#!/bin/sh\necho \"$*\" >> {systemctl_log}\n")
            fake_systemctl.chmod(0o755)
            linux_prefix = td_path / "prefix-linux-svc"
            linux_bin = td_path / "bin-linux-svc"
            linux_data = td_path / "data-linux-svc"
            xdg = td_path / "xdg-config"
            env_linux_svc = {
                **base_env,
                "PATH": f"{fake_bin}:{base_env['PATH']}",
                "XDG_CONFIG_HOME": str(xdg),
                "H_RELEASE_URL": f"{base}/v2",
                "H_OS": "Linux",
                "H_ARCH": "x86_64",
            }
            res = run_install(
                script,
                env_linux_svc,
                "--prefix",
                str(linux_prefix),
                "--bin-dir",
                str(linux_bin),
                "--data-dir",
                str(linux_data),
                "--service",
            )
            assert res.returncode == 0, f"linux --service failed: {res.stderr}"
            unit_file = xdg / "systemd/user/harness-daemon.service"
            assert unit_file.is_file()
            unit_text = unit_file.read_text()
            assert f'ExecStart="{linux_prefix}/current/bin/h-daemon" --data-dir "{linux_data}"' in unit_text
            assert "Restart=on-failure" in unit_text
            assert "TimeoutStopSec=660" in unit_text
            sc_calls = systemctl_log.read_text().splitlines()
            assert sc_calls == [
                "--user daemon-reload",
                "--user enable harness-daemon.service",
                "--user restart harness-daemon.service",
            ]

            # 8. Cascading writable PATH bin directory selection (resort to ~/.bin only last)
            cascade_home = td_path / "cascade-home"
            pref_usr = td_path / "pref-usr-local-bin"
            pref_opt = td_path / "pref-opt-local-bin"
            pref_brew = td_path / "pref-opt-homebrew-bin"
            unwritable_usr = td_path / "missing-root/usr-local-bin"
            unwritable_opt = td_path / "missing-root/opt-local-bin"
            unwritable_brew = td_path / "missing-root/homebrew-bin"
            custom_bin = td_path / "custom-user-bin"
            shims_bin = td_path / "asdf/shims"
            cargo_bin = cascade_home / ".cargo/bin"
            home_bin = cascade_home / ".bin"
            for d in (cascade_home, pref_usr, pref_opt, pref_brew, custom_bin, shims_bin, cargo_bin, home_bin):
                d.mkdir(parents=True)

            try:
                pref_list = f"{pref_usr}:{pref_opt}:{pref_brew}"
                sys_path = "/usr/bin:/bin"

                # 8a. Writable preferred dir on PATH wins over ~/.bin even when ~/.bin is first in PATH
                p_8a = td_path / "prefix-cascade-8a"
                env_8a = {
                    **base_env,
                    "HOME": str(cascade_home),
                    "PATH": f"{home_bin}:{pref_opt}:{pref_usr}:{sys_path}",
                    "H_PREFERRED_BIN_DIRS": pref_list,
                    "H_RELEASE_URL": f"{base}/v2",
                    "H_OS": "Darwin",
                    "H_ARCH": "arm64",
                }
                res = run_install(script, env_8a, "--prefix", str(p_8a))
                assert res.returncode == 0, f"cascade 8a failed: {res.stderr}"
                assert (pref_usr / "hi").is_symlink()
                assert not (home_bin / "hi").exists()
                assert "Add " not in res.stdout

                # 8b. Non-writable first preferred dir is skipped in favor of next writable preferred dir
                #     (In root CI containers, chmod 0555 remains writable by UID 0, so use missing-root when uid==0.)
                if os.geteuid() != 0:
                    os.chmod(pref_usr, 0o555)
                    pref_list_8b = pref_list
                    first_unwritable = pref_usr
                else:
                    pref_list_8b = f"{unwritable_usr}:{pref_opt}:{pref_brew}"
                    first_unwritable = unwritable_usr

                p_8b = td_path / "prefix-cascade-8b"
                env_8b = {
                    **env_8a,
                    "H_PREFERRED_BIN_DIRS": pref_list_8b,
                    "PATH": f"{first_unwritable}:{pref_opt}:{home_bin}:{sys_path}",
                }
                res = run_install(script, env_8b, "--prefix", str(p_8b))
                assert res.returncode == 0, f"cascade 8b failed: {res.stderr}"
                assert (pref_opt / "hi").is_symlink()
                assert not (home_bin / "hi").exists()

                # 8c. When preferred dirs are non-writable and shims/.cargo/bin are present,
                #     other writable PATH dir wins over ~/.bin
                if os.geteuid() != 0:
                    os.chmod(pref_opt, 0o555)
                    os.chmod(pref_brew, 0o555)
                    pref_list_8c = pref_list
                else:
                    pref_list_8c = f"{unwritable_usr}:{unwritable_opt}:{unwritable_brew}"

                p_8c = td_path / "prefix-cascade-8c"
                env_8c = {
                    **env_8a,
                    "H_PREFERRED_BIN_DIRS": pref_list_8c,
                    "PATH": f".:{shims_bin}:{cargo_bin}:{home_bin}:{custom_bin}:{sys_path}",
                }
                res = run_install(script, env_8c, "--prefix", str(p_8c))
                assert res.returncode == 0, f"cascade 8c failed: {res.stderr}"
                assert (custom_bin / "hi").is_symlink()
                assert not (home_bin / "hi").exists()

                # 8d. ~/.bin used strictly as last resort when nothing else writable is available
                p_8d = td_path / "prefix-cascade-8d"
                env_8d = {
                    **env_8a,
                    "H_PREFERRED_BIN_DIRS": pref_list_8c,
                    "PATH": f"{first_unwritable}:{shims_bin}:{cargo_bin}:{sys_path}",
                }
                res = run_install(script, env_8d, "--prefix", str(p_8d))
                assert res.returncode == 0, f"cascade 8d failed: {res.stderr}"
                assert (home_bin / "hi").is_symlink()
                assert f"Add {home_bin} to PATH" in res.stdout
            finally:
                for d in (pref_usr, pref_opt, pref_brew):
                    os.chmod(d, 0o755)
        finally:
            server.shutdown()
            server.server_close()

    print(
        f"test-install-sh.py passed ({line_count} lines): darwin-arm64, linux-arm64, linux-x86_64, "
        "atomic upgrade & rollback retention, checksum/signature tamper rejection, conflict refusal, and Linux systemd --user service."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
