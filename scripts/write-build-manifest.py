#!/usr/bin/env python3
"""Generate BUILD_MANIFEST.json for a built H standalone bundle."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import re
import subprocess
import sys


def detect_target() -> str:
    sys_os = platform.system().lower()
    if sys_os not in ("darwin", "linux"):
        raise SystemExit(f"Unsupported OS for bundle target: {sys_os}")
    machine = platform.machine().lower()
    arch_map = {
        "arm64": "arm64",
        "aarch64": "arm64",
        "x86_64": "x86_64",
        "amd64": "x86_64",
    }
    arch = arch_map.get(machine)
    if arch is None:
        raise SystemExit(f"Unsupported architecture for bundle target: {machine}")
    return f"{sys_os}-{arch}"


def read_mix_version(mix_exs: Path) -> str:
    text = mix_exs.read_text(encoding="utf-8")
    match = re.search(r'version:\s*"([^"]+)"', text)
    if not match:
        raise SystemExit(f"Could not parse version from {mix_exs}")
    return match.group(1)


def read_git(root: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(root), *args],
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def detect_erts_version(bundle: Path) -> str:
    start_erl = bundle / "releases/start_erl.data"
    if start_erl.is_file():
        parts = start_erl.read_text(encoding="utf-8").strip().split()
        if parts:
            return parts[0]
    erts_dirs = sorted(bundle.glob("erts-*"))
    if erts_dirs:
        return erts_dirs[0].name.removeprefix("erts-")
    return ""


def detect_otp_and_elixir() -> tuple[str, str]:
    proc = subprocess.run(
        [
            "elixir",
            "-e",
            'IO.puts("#{System.otp_release()}|#{System.version()}")',
        ],
        text=True,
        capture_output=True,
    )
    if proc.returncode == 0:
        lines = [line.strip() for line in proc.stdout.splitlines() if "|" in line]
        if lines:
            otp, ex = lines[-1].split("|", 1)
            return otp.strip(), ex.strip()
    return "", ""


def main():
    parser = argparse.ArgumentParser(description="Write BUILD_MANIFEST.json into a bundle root")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--bundle-root", required=True, type=Path)
    parser.add_argument("--version", default="")
    parser.add_argument("--git-commit", default="")
    parser.add_argument("--git-tag", default="")
    parser.add_argument("--target", default="")
    args = parser.parse_args()

    source_root = args.source_root.resolve()
    bundle_root = args.bundle_root.resolve()

    mix_version = read_mix_version(source_root / "mix.exs")
    version = args.version.strip() or mix_version
    if version != mix_version:
        raise SystemExit(
            f"H_RELEASE_VERSION ({version}) does not match mix.exs version ({mix_version})"
        )

    git_commit = args.git_commit.strip() or read_git(source_root, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", git_commit):
        raise SystemExit(
            f"Expected 40-character git commit SHA (set H_GIT_COMMIT if building outside .git), got: {git_commit!r}"
        )

    git_tag = args.git_tag.strip() or read_git(source_root, "describe", "--tags", "--exact-match")
    target = args.target.strip() or detect_target()
    erts_version = detect_erts_version(bundle_root)
    otp_release, elixir_version = detect_otp_and_elixir()

    manifest = {
        "schema_version": 1,
        "name": "harness",
        "version": version,
        "git_commit": git_commit,
        "git_tag": git_tag or None,
        "target": target,
        "erts_version": erts_version,
        "otp_release": otp_release,
        "elixir_version": elixir_version,
        "built_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    dest = bundle_root / "BUILD_MANIFEST.json"
    dest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {dest.name} ({version}, {target}, commit {git_commit[:12]})")


if __name__ == "__main__":
    main()
