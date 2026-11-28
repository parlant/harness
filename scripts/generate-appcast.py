#!/usr/bin/env python3
"""Generate a Sparkle 2 appcast.xml for H.app macOS releases.

Signs the H-v<version>-darwin-arm64.app.zip enclosure with Ed25519 (standard
Sparkle 2 `sparkle:edSignature` format) using OpenSSL and the same Ed25519
signing key as `scripts/sign-release.sh` (or an explicit Sparkle base64 seed).

Usage:
  scripts/generate-appcast.py <release-dir> [--output <path>] [--download-base-url <url>]

Environment variables (key resolution, first match wins):
  H_SPARKLE_PRIVATE_KEY  Raw 32-byte Ed25519 seed (base64, Sparkle export format)
  H_SIGNING_KEY_PEM      OpenSSH Ed25519 private key PEM (as in GitLab CI)
  H_SIGNING_KEY          Path to OpenSSH Ed25519 private key file
  ~/.ssh/harness/release_signing_ed25519
  ~/.ssh/id_ed25519
  H_ALLOW_UNSIGNED=1     Emit appcast without sparkle:edSignature if no key exists
"""

from __future__ import annotations

import argparse
import base64
from email.utils import format_datetime
from datetime import datetime, timezone
import html
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape

# RFC 8410 PKCS#8 DER prefix for a 32-byte Ed25519 private seed
ED25519_PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")


def _read_ssh_string(buf: bytes, pos: int) -> tuple[bytes, int]:
    if pos + 4 > len(buf):
        raise ValueError("Truncated OpenSSH key buffer")
    (length,) = struct.unpack(">I", buf[pos : pos + 4])
    pos += 4
    if pos + length > len(buf):
        raise ValueError("Truncated OpenSSH key string")
    return buf[pos : pos + length], pos + length


def extract_ed25519_seed_from_openssh(pem_text: str) -> bytes:
    """Extract the raw 32-byte Ed25519 seed from an unencrypted OpenSSH key."""
    lines = [
        line.strip()
        for line in pem_text.splitlines()
        if line.strip() and not line.strip().startswith("-----")
    ]
    raw = base64.b64decode("".join(lines))
    magic = b"openssh-key-v1\x00"
    if not raw.startswith(magic):
        raise ValueError("Not an openssh-key-v1 private key")
    pos = len(magic)
    cipher, pos = _read_ssh_string(raw, pos)
    kdf, pos = _read_ssh_string(raw, pos)
    _kdfopts, pos = _read_ssh_string(raw, pos)
    if cipher != b"none" or kdf != b"none":
        raise ValueError(f"Encrypted OpenSSH keys are not supported (cipher={cipher!r})")
    (nkeys,) = struct.unpack(">I", raw[pos : pos + 4])
    pos += 4
    if nkeys < 1:
        raise ValueError("OpenSSH key contains no keys")
    _pub_blob, pos = _read_ssh_string(raw, pos)
    priv_blob, pos = _read_ssh_string(raw, pos)

    check1, check2 = struct.unpack(">II", priv_blob[:8])
    if check1 != check2:
        raise ValueError("OpenSSH private key checkint mismatch")
    p = 8
    key_type, p = _read_ssh_string(priv_blob, p)
    if key_type != b"ssh-ed25519":
        raise ValueError(f"Expected ssh-ed25519 key, got {key_type!r}")
    _pk, p = _read_ssh_string(priv_blob, p)
    sk, p = _read_ssh_string(priv_blob, p)
    if len(sk) != 64:
        raise ValueError(f"Unexpected Ed25519 private key length: {len(sk)}")
    return sk[:32]


def resolve_ed25519_seed() -> bytes | None:
    if raw_seed := os.environ.get("H_SPARKLE_PRIVATE_KEY", "").strip():
        decoded = base64.b64decode(raw_seed)
        if len(decoded) not in (32, 64):
            raise SystemExit(f"H_SPARKLE_PRIVATE_KEY decoded to {len(decoded)} bytes (expected 32 or 64)")
        return decoded[:32]

    if pem := os.environ.get("H_SIGNING_KEY_PEM", "").strip():
        return extract_ed25519_seed_from_openssh(pem)

    candidates: list[Path] = []
    if env_key := os.environ.get("H_SIGNING_KEY", "").strip():
        candidates.append(Path(env_key))
    home = Path.home()
    candidates.append(home / ".ssh" / "harness" / "release_signing_ed25519")
    candidates.append(home / ".ssh" / "id_ed25519")

    for path in candidates:
        if path.is_file():
            text = path.read_text(encoding="utf-8")
            return extract_ed25519_seed_from_openssh(text)

    return None


def sign_file_ed25519(file_path: Path, seed: bytes) -> str:
    """Produce a Sparkle-compatible base64 Ed25519 signature using openssl."""
    pkcs8_der = ED25519_PKCS8_PREFIX + seed
    pkcs8_pem = (
        "-----BEGIN PRIVATE KEY-----\n"
        + base64.b64encode(pkcs8_der).decode("ascii")
        + "\n-----END PRIVATE KEY-----\n"
    )
    with tempfile.TemporaryDirectory(prefix="h-sparkle-sign-") as td:
        td_path = Path(td)
        pem_path = td_path / "ed25519.pem"
        sig_path = td_path / "sig.bin"
        pem_path.write_text(pkcs8_pem, encoding="utf-8")
        os.chmod(pem_path, 0o600)
        subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-sign",
                "-inkey",
                str(pem_path),
                "-rawin",
                "-in",
                str(file_path),
                "-out",
                str(sig_path),
            ],
            check=True,
        )
        sig = sig_path.read_bytes()
        if len(sig) != 64:
            raise SystemExit(f"Unexpected Ed25519 signature length: {len(sig)}")
        return base64.b64encode(sig).decode("ascii")


def _render_inline(text: str) -> str:
    escaped = html.escape(text)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)


def load_release_notes_html(repo_root: Path, version: str, commit: str) -> str:
    """Render concise HTML release notes from websites/shared/data/releases.yml if present."""
    releases_yml = repo_root / "websites" / "shared" / "data" / "releases.yml"
    title = None
    summary = None
    highlights: list[str] = []

    if releases_yml.is_file():
        lines = releases_yml.read_text(encoding="utf-8").splitlines()
        in_entry = False
        in_highlights = False
        for line in lines:
            m_ver = re.match(r'^\s*-\s+version:\s*"?([^"\s]+)"?\s*$', line)
            if m_ver:
                if in_entry:
                    break
                if m_ver.group(1) == version:
                    in_entry = True
                continue
            if not in_entry:
                continue
            if re.match(r'^\s*highlights:\s*$', line):
                in_highlights = True
                continue
            if in_highlights:
                m_hl = re.match(r'^\s*-\s+"(.*)"\s*$', line)
                if m_hl:
                    highlights.append(m_hl.group(1).replace('\\"', '"'))
                    continue
                elif re.match(r'^\s*[a-z_]+:', line):
                    in_highlights = False
            m_title = re.match(r'^\s*title:\s*"(.*)"\s*$', line)
            if m_title:
                title = m_title.group(1).replace('\\"', '"')
            m_sum = re.match(r'^\s*summary:\s*"(.*)"\s*$', line)
            if m_sum:
                summary = m_sum.group(1).replace('\\"', '"')

    parts: list[str] = []
    if title:
        parts.append(f"<h2>{_render_inline(title)}</h2>")
    if summary:
        parts.append(f"<p>{_render_inline(summary)}</p>")
    if highlights:
        items_html = "".join(f"<li>{_render_inline(h)}</li>" for h in highlights)
        parts.append(f"<ul>{items_html}</ul>")

    if not parts:
        short_commit = f" (commit <code>{html.escape(commit[:12])}</code>)" if commit else ""
        parts.append(f"<p>H v{html.escape(version)}{short_commit}.</p>")

    parts.append(
        f'<p><a href="https://hiness.dev/releases/">Full release notes &amp; downloads</a></p>'
    )
    return "\n".join(parts)


def find_app_zips(rel_dir: Path, version: str) -> list[tuple[str, Path]]:
    """Return list of (sparkle_arch, zip_path) for macOS H.app zip bundles."""
    matches: list[tuple[str, Path]] = []
    arch_map = {
        "darwin-arm64": "arm64",
        "darwin-x86_64": "x86_64",
    }
    for target, sparkle_arch in arch_map.items():
        candidate = rel_dir / f"H-v{version}-{target}.app.zip"
        if candidate.is_file():
            matches.append((sparkle_arch, candidate))
    return matches


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Sparkle 2 appcast.xml for H.app")
    parser.add_argument("release_dir", type=Path, help="Release directory containing H-v*.app.zip")
    parser.add_argument("--output", type=Path, default=None, help="Output path (defaults to <release-dir>/appcast.xml)")
    parser.add_argument("--version", default="", help="Override release version")
    parser.add_argument("--tag", default="", help="Override git tag (defaults to v<version>)")
    parser.add_argument(
        "--download-base-url",
        default="",
        help="Base URL prefix where H-v*.app.zip is hosted (defaults to GitHub release download URL)",
    )
    parser.add_argument(
        "--github-repo",
        default=os.environ.get("GITHUB_RELEASE_REPO", "parlant/harness"),
        help="GitHub owner/repo for default download URL",
    )
    parser.add_argument(
        "--min-macos",
        default="14.0",
        help="Minimum macOS version (sparkle:minimumSystemVersion)",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    rel_dir = args.release_dir.resolve()
    manifest_path = rel_dir / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {}

    version = args.version.strip() or str(manifest.get("version") or "").strip()
    if not version:
        raise SystemExit("Could not determine release version (pass --version or provide release-manifest.json)")
    tag = args.tag.strip() or str(manifest.get("git_tag") or "").strip() or f"v{version}"
    commit = str(manifest.get("git_commit") or "").strip()

    app_zips = find_app_zips(rel_dir, version)
    if not app_zips:
        print(f"No H-v{version}-darwin-*.app.zip found in {rel_dir}; skipping appcast.xml", file=sys.stderr)
        return 0

    seed = resolve_ed25519_seed()
    if seed is None and os.environ.get("H_ALLOW_UNSIGNED", "0") != "1":
        raise SystemExit(
            "No Ed25519 signing key found for Sparkle appcast "
            "(set H_SPARKLE_PRIVATE_KEY, H_SIGNING_KEY_PEM, or H_SIGNING_KEY)"
        )

    download_base = args.download_base_url.strip().rstrip("/")
    if not download_base:
        download_base = f"https://github.com/{args.github_repo}/releases/download/{tag}"

    pub_date = format_datetime(datetime.now(timezone.utc))
    notes_html = load_release_notes_html(repo_root, version, commit)
    # Guard against literal ']]>' in CDATA
    notes_cdata = notes_html.replace("]]>", "]]]]><![CDATA[>")
    is_prerelease = "-" in version

    item_blocks: list[str] = []
    for sparkle_arch, zip_path in app_zips:
        length = zip_path.stat().st_size
        enclosure_url = f"{download_base}/{zip_path.name}"
        ed_attr = ""
        if seed is not None:
            sig = sign_file_ed25519(zip_path, seed)
            ed_attr = f' sparkle:edSignature="{escape(sig)}"'

        channel_line = "\n            <sparkle:channel>beta</sparkle:channel>" if is_prerelease else ""
        # When only a single architecture exists we still declare sparkle:os="macos"
        # and sparkle:hardwareRequirements/arch via enclosure or item if needed.
        # Sparkle 2 supports sparkle:os="macos" on <enclosure>.
        item_blocks.append(
            f"""        <item>
            <title>H {escape(version)}</title>
            <link>https://hiness.app</link>
            <sparkle:version>{escape(version)}</sparkle:version>
            <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{escape(args.min_macos)}</sparkle:minimumSystemVersion>{channel_line}
            <sparkle:fullReleaseNotesLink>https://hiness.dev/releases/</sparkle:fullReleaseNotesLink>
            <pubDate>{escape(pub_date)}</pubDate>
            <description><![CDATA[
{notes_cdata}
            ]]></description>
            <enclosure
                url="{escape(enclosure_url)}"
                length="{length}"
                type="application/octet-stream"
                sparkle:os="macos"{ed_attr} />
        </item>"""
        )

    xml_text = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <channel>\n"
        "        <title>H for macOS Updates</title>\n"
        "        <link>https://hiness.app</link>\n"
        "        <description>Signed updates for H.app (macOS)</description>\n"
        "        <language>en</language>\n"
        + "\n".join(item_blocks)
        + "\n    </channel>\n"
        "</rss>\n"
    )

    out_path = args.output.resolve() if args.output else (rel_dir / "appcast.xml")
    out_path.write_text(xml_text, encoding="utf-8")
    signed_note = "signed with Ed25519" if seed is not None else "UNSIGNED (H_ALLOW_UNSIGNED=1)"
    print(f"Wrote {out_path} for H v{version} ({len(app_zips)} macOS archive(s), {signed_note})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
