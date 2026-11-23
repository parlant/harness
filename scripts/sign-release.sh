#!/bin/sh
# Generate SHA256SUMS + source-tied release-manifest.json and sign both with
# OpenSSH (`ssh-keygen -Y sign -n file`).
#
# Usage: scripts/sign-release.sh <release-dir>
#
# Key resolution (first match wins):
#   1. H_SIGNING_KEY_PEM  (raw private key material, e.g. GitLab CI masked/file var)
#   2. H_SIGNING_KEY      (path to private key file)
#   3. $HOME/.ssh/harness/release_signing_ed25519
#   4. $HOME/.ssh/id_ed25519
#
# Optional:
#   H_ALLOW_UNSIGNED=1    generate SHA256SUMS + release-manifest.json without signing
#                         if no signing key is available.
#   H_GIT_COMMIT / H_GIT_TAG / H_RELEASE_VERSION  override git metadata when outside .git
set -eu

if [ "$#" != 1 ]; then
  echo 'Usage: scripts/sign-release.sh <release-dir>' >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
rel_dir=$(CDPATH= cd -- "$1" && pwd -P)

# 1. Generate SHA256SUMS + release-manifest.json deterministically.
python3 - "$root" "$rel_dir" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

root = Path(sys.argv[1]).resolve()
rel_dir = Path(sys.argv[2]).resolve()

ARTIFACT_SUFFIXES = (".tar.gz", ".dmg", ".zip", ".ez")


def is_artifact(path: Path) -> bool:
    if not path.is_file():
        return False
    name = path.name
    return any(name.endswith(sfx) for sfx in ARTIFACT_SUFFIXES)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def git_out(*args: str) -> str:
    proc = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def extract_tarball_manifest(tar_path: Path):
    with tarfile.open(tar_path, "r:gz") as tf:
        for member in tf.getmembers():
            if member.name == "harness/BUILD_MANIFEST.json":
                fh = tf.extractfile(member)
                if fh is None:
                    raise SystemExit(f"Empty BUILD_MANIFEST.json in {tar_path.name}")
                raw = fh.read()
                return json.loads(raw.decode("utf-8")), hashlib.sha256(raw).hexdigest()
    raise SystemExit(f"Archive {tar_path.name} is missing harness/BUILD_MANIFEST.json")


artifacts = sorted((p for p in rel_dir.iterdir() if is_artifact(p)), key=lambda p: p.name)
if not artifacts:
    raise SystemExit(f"No release artifacts (*.tar.gz, *.dmg, *.zip, *.ez) found in {rel_dir}")

git_commit = os.environ.get("H_GIT_COMMIT", "").strip() or git_out("rev-parse", "HEAD")
git_tree = os.environ.get("H_GIT_TREE", "").strip() or git_out("rev-parse", f"{git_commit}^{{tree}}") if git_commit else ""
git_tag = os.environ.get("H_GIT_TAG", "").strip() or git_out("describe", "--tags", "--exact-match")

mix_match = re.search(r'(?:@version\s+|version:\s*)"([^"]+)"', (root / "mix.exs").read_text(encoding="utf-8"))
mix_version = mix_match.group(1) if mix_match else ""
version = os.environ.get("H_RELEASE_VERSION", "").strip() or mix_version

sum_lines = []
manifest_artifacts = []
manifest_versions = set()
manifest_commits = set()

for path in artifacts:
    digest = sha256_file(path)
    sum_lines.append(f"{digest}  {path.name}\n")
    entry = {
        "name": path.name,
        "size": path.stat().st_size,
        "sha256": digest,
    }
    if path.name.endswith(".tar.gz"):
        bm, bm_sha = extract_tarball_manifest(path)
        entry["build_manifest_sha256"] = bm_sha
        entry["target"] = bm.get("target")
        entry["version"] = bm.get("version")
        entry["git_commit"] = bm.get("git_commit")
        entry["erts_version"] = bm.get("erts_version")
        entry["otp_release"] = bm.get("otp_release")
        entry["elixir_version"] = bm.get("elixir_version")
        if bm.get("version"):
            manifest_versions.add(bm["version"])
        if bm.get("git_commit"):
            manifest_commits.add(bm["git_commit"])
    manifest_artifacts.append(entry)

if len(manifest_versions) > 1:
    raise SystemExit(f"Conflicting versions across tarballs: {sorted(manifest_versions)}")
if len(manifest_commits) > 1:
    raise SystemExit(f"Conflicting git commits across tarballs: {sorted(manifest_commits)}")

if manifest_versions:
    bm_version = next(iter(manifest_versions))
    if version and version != bm_version:
        raise SystemExit(f"Release version ({version}) does not match tarball BUILD_MANIFEST.json ({bm_version})")
    version = bm_version

if manifest_commits:
    bm_commit = next(iter(manifest_commits))
    if git_commit and git_commit != bm_commit:
        raise SystemExit(f"Git commit ({git_commit}) does not match tarball BUILD_MANIFEST.json ({bm_commit})")
    git_commit = bm_commit

sums_text = "".join(sum_lines)
(rel_dir / "SHA256SUMS").write_text(sums_text, encoding="utf-8")

manifest = {
    "schema_version": 1,
    "name": "harness",
    "version": version,
    "git_commit": git_commit,
    "git_tree": git_tree or None,
    "git_tag": git_tag or None,
    "sha256sums_sha256": hashlib.sha256(sums_text.encode("utf-8")).hexdigest(),
    "artifacts": manifest_artifacts,
}
(rel_dir / "release-manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(f"Wrote SHA256SUMS and release-manifest.json for {len(artifacts)} artifact(s) (version {version}, commit {git_commit[:12]})")
PY

# 2. Sign SHA256SUMS and release-manifest.json with OpenSSH Ed25519 key.
tmp_key=""
cleanup() {
  if [ -n "$tmp_key" ] && [ -f "$tmp_key" ]; then
    rm -f -- "$tmp_key"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

key_file=""
make_tmp_key() {
  case $(uname -s) in
    Darwin) tmpdir=/private/tmp ;;
    *) tmpdir=${TMPDIR:-/tmp} ;;
  esac
  tmp_key=$(mktemp "$tmpdir/h-sign-key.XXXXXX")
  chmod 600 "$tmp_key"
}

if [ -n "${H_SIGNING_KEY_PEM:-}" ]; then
  make_tmp_key
  printf '%s\n' "$H_SIGNING_KEY_PEM" > "$tmp_key"
  key_file="$tmp_key"
elif [ -n "${H_SIGNING_KEY:-}" ] && [ -f "$H_SIGNING_KEY" ]; then
  # Copy file-type CI variables (which GitLab Runner mounts mode 0666) to a 0600 temp file.
  make_tmp_key
  cp -- "$H_SIGNING_KEY" "$tmp_key"
  chmod 600 "$tmp_key"
  key_file="$tmp_key"
elif [ -n "${H_SIGNING_KEY:-}" ]; then
  key_file="$H_SIGNING_KEY"
elif [ -f "${HOME:-}/.ssh/harness/release_signing_ed25519" ]; then
  key_file="${HOME}/.ssh/harness/release_signing_ed25519"
elif [ -f "${HOME:-}/.ssh/id_ed25519" ]; then
  key_file="${HOME}/.ssh/id_ed25519"
fi

if [ -z "$key_file" ] || [ ! -f "$key_file" ]; then
  if [ "${H_ALLOW_UNSIGNED:-0}" = "1" ]; then
    echo "Warning: no signing key available; skipping OpenSSH signatures (H_ALLOW_UNSIGNED=1)" >&2
    exit 0
  fi
  echo "No OpenSSH signing key found (set H_SIGNING_KEY or H_SIGNING_KEY_PEM)" >&2
  exit 1
fi

rm -f "$rel_dir/SHA256SUMS.sig" "$rel_dir/release-manifest.json.sig"
ssh-keygen -Y sign -n file -f "$key_file" "$rel_dir/SHA256SUMS"
ssh-keygen -Y sign -n file -f "$key_file" "$rel_dir/release-manifest.json"
echo "Signed SHA256SUMS.sig and release-manifest.json.sig"
