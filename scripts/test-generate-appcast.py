#!/usr/bin/env python3
"""Unit tests for scripts/generate-appcast.py (Sparkle 2 appcast generation & Ed25519 signing)."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
GEN_SCRIPT = ROOT / "scripts" / "generate-appcast.py"
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def extract_pubkey_from_ssh_pub(pub_line: str) -> bytes:
    parts = pub_line.strip().split()
    blob = base64.b64decode(parts[1])
    (n,) = struct.unpack(">I", blob[:4])
    p = 4 + n
    (n2,) = struct.unpack(">I", blob[p : p + 4])
    pk = blob[p + 4 : p + 4 + n2]
    assert len(pk) == 32
    return pk


def verify_ed25519_openssl(file_path: Path, pubkey_raw: bytes, sig_b64: str) -> None:
    spki_der = ED25519_SPKI_PREFIX + pubkey_raw
    spki_pem = (
        "-----BEGIN PUBLIC KEY-----\n"
        + base64.b64encode(spki_der).decode("ascii")
        + "\n-----END PUBLIC KEY-----\n"
    )
    with tempfile.TemporaryDirectory() as td:
        pub_path = Path(td) / "pub.pem"
        sig_path = Path(td) / "sig.bin"
        pub_path.write_text(spki_pem, encoding="utf-8")
        sig_path.write_bytes(base64.b64decode(sig_b64))
        subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-verify",
                "-pubin",
                "-inkey",
                str(pub_path),
                "-rawin",
                "-in",
                str(file_path),
                "-sigfile",
                str(sig_path),
            ],
            check=True,
        )


class GenerateAppcastTest(unittest.TestCase):
    def test_generates_and_signs_appcast_with_openssh_ed25519_key(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            key_path = td_path / "test_ed25519"
            subprocess.run(
                ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path), "-q"],
                check=True,
            )
            pubkey_raw = extract_pubkey_from_ssh_pub((td_path / "test_ed25519.pub").read_text())

            rel_dir = td_path / "release"
            rel_dir.mkdir()
            zip_path = rel_dir / "H-v0.5.1-darwin-arm64.app.zip"
            zip_payload = b"PK\x03\x04fake-notarized-h-app-bundle-zip"
            zip_path.write_bytes(zip_payload)
            (rel_dir / "release-manifest.json").write_text(
                json.dumps(
                    {
                        "version": "0.5.1",
                        "git_tag": "v0.5.1",
                        "git_commit": "8daf706933ded23c00828df403db0ad747b6e2f5",
                    }
                ),
                encoding="utf-8",
            )

            env = os.environ.copy()
            env.pop("H_SPARKLE_PRIVATE_KEY", None)
            env.pop("H_SIGNING_KEY_PEM", None)
            env["H_SIGNING_KEY"] = str(key_path)

            subprocess.run(
                [sys.executable, str(GEN_SCRIPT), str(rel_dir)],
                env=env,
                check=True,
            )

            appcast_path = rel_dir / "appcast.xml"
            self.assertTrue(appcast_path.is_file())

            root = ET.parse(appcast_path).getroot()
            item = root.find("./channel/item")
            self.assertIsNotNone(item)
            self.assertEqual(item.findtext(f"{SPARKLE_NS}version"), "0.5.1")
            self.assertEqual(item.findtext(f"{SPARKLE_NS}shortVersionString"), "0.5.1")
            self.assertEqual(item.findtext(f"{SPARKLE_NS}minimumSystemVersion"), "14.0")
            self.assertIsNone(item.find(f"{SPARKLE_NS}channel"))

            desc = item.findtext("description") or ""
            self.assertIn("Prevent hi CPU spin on terminal disconnect", desc)
            self.assertIn("<code>use-dev-tty</code>", desc)

            enc = item.find("enclosure")
            self.assertIsNotNone(enc)
            self.assertEqual(
                enc.attrib["url"],
                "https://github.com/parlant/harness/releases/download/v0.5.1/H-v0.5.1-darwin-arm64.app.zip",
            )
            self.assertEqual(enc.attrib["length"], str(len(zip_payload)))
            self.assertEqual(enc.attrib[f"{SPARKLE_NS}os"], "macos")

            ed_sig = enc.attrib[f"{SPARKLE_NS}edSignature"]
            verify_ed25519_openssl(zip_path, pubkey_raw, ed_sig)

    def test_prerelease_uses_beta_channel_and_pem_env_var(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            key_path = td_path / "test_ed25519"
            subprocess.run(
                ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path), "-q"],
                check=True,
            )
            pubkey_raw = extract_pubkey_from_ssh_pub((td_path / "test_ed25519.pub").read_text())

            rel_dir = td_path / "release"
            rel_dir.mkdir()
            zip_path = rel_dir / "H-v0.6.0-rc.1-darwin-arm64.app.zip"
            zip_path.write_bytes(b"prerelease-zip")

            env = os.environ.copy()
            env.pop("H_SPARKLE_PRIVATE_KEY", None)
            env.pop("H_SIGNING_KEY", None)
            env["H_SIGNING_KEY_PEM"] = key_path.read_text(encoding="utf-8")

            subprocess.run(
                [
                    sys.executable,
                    str(GEN_SCRIPT),
                    str(rel_dir),
                    "--version",
                    "0.6.0-rc.1",
                    "--download-base-url",
                    "https://example.test/releases/v0.6.0-rc.1",
                ],
                env=env,
                check=True,
            )

            root = ET.parse(rel_dir / "appcast.xml").getroot()
            item = root.find("./channel/item")
            self.assertEqual(item.findtext(f"{SPARKLE_NS}channel"), "beta")
            enc = item.find("enclosure")
            self.assertEqual(
                enc.attrib["url"],
                "https://example.test/releases/v0.6.0-rc.1/H-v0.6.0-rc.1-darwin-arm64.app.zip",
            )
            verify_ed25519_openssl(zip_path, pubkey_raw, enc.attrib[f"{SPARKLE_NS}edSignature"])

    def test_skips_cleanly_when_no_macos_app_zip_present(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            rel_dir = Path(td)
            (rel_dir / "release-manifest.json").write_text(
                json.dumps({"version": "0.5.2", "git_tag": "v0.5.2"}),
                encoding="utf-8",
            )
            res = subprocess.run(
                [sys.executable, str(GEN_SCRIPT), str(rel_dir)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertFalse((rel_dir / "appcast.xml").exists())
            self.assertIn("skipping appcast.xml", res.stderr)


if __name__ == "__main__":
    unittest.main()
