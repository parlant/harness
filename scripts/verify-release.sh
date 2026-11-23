#!/bin/sh
# Verify OpenSSH signatures, SHA-256 digests, and embedded BUILD_MANIFEST.json
# source provenance for an H release directory.
#
# Usage: scripts/verify-release.sh <release-dir>
#
# Optional environment variables:
#   H_ALLOWED_SIGNERS   path to allowed_signers file
#                       (defaults to packaging/keys/release-signers)
#   H_SIGNER_IDENTITY   signer principal (defaults to l.rieder@gmail.com)
#   H_ALLOW_UNSIGNED=1  allow missing .sig files (still verifies SHA256SUMS and
#                       embedded BUILD_MANIFEST.json provenance)
set -eu

if [ "$#" != 1 ]; then
  echo 'Usage: scripts/verify-release.sh <release-dir>' >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
rel_dir=$(CDPATH= cd -- "$1" && pwd -P)
signers="${H_ALLOWED_SIGNERS:-$root/packaging/keys/release-signers}"
identity="${H_SIGNER_IDENTITY:-l.rieder@gmail.com}"

sums="$rel_dir/SHA256SUMS"
manifest="$rel_dir/release-manifest.json"
sums_sig="$rel_dir/SHA256SUMS.sig"
manifest_sig="$rel_dir/release-manifest.json.sig"

for req in "$sums" "$manifest"; do
  if [ ! -f "$req" ]; then
    echo "Missing required release file: $req" >&2
    exit 1
  fi
done

verify_sig() {
  target_file="$1"
  sig_file="$2"
  if [ ! -f "$sig_file" ]; then
    if [ "${H_ALLOW_UNSIGNED:-0}" = "1" ]; then
      echo "Warning: skipping missing signature $sig_file (H_ALLOW_UNSIGNED=1)" >&2
      return 0
    fi
    echo "Missing signature file: $sig_file" >&2
    exit 1
  fi
  if [ ! -f "$signers" ]; then
    echo "Missing allowed_signers file: $signers" >&2
    exit 1
  fi
  ssh-keygen -Y verify \
    -f "$signers" \
    -I "$identity" \
    -n file \
    -s "$sig_file" < "$target_file"
}

verify_sig "$sums" "$sums_sig"
verify_sig "$manifest" "$manifest_sig"

python3 - "$rel_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import tarfile

rel_dir = Path(sys.argv[1]).resolve()
sums_path = rel_dir / "SHA256SUMS"
manifest_path = rel_dir / "release-manifest.json"

sums_text = sums_path.read_text(encoding="utf-8")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

expected_sums_sha = manifest.get("sha256sums_sha256")
actual_sums_sha = hashlib.sha256(sums_text.encode("utf-8")).hexdigest()
if expected_sums_sha != actual_sums_sha:
    raise SystemExit(
        f"release-manifest.json sha256sums_sha256 mismatch: expected {expected_sums_sha}, got {actual_sums_sha}"
    )


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


# Parse SHA256SUMS
sums_map = {}
for line in sums_text.splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) != 2:
        raise SystemExit(f"Malformed SHA256SUMS line: {line!r}")
    digest, filename = parts[0], parts[1].lstrip("*")
    if filename in sums_map:
        raise SystemExit(f"Duplicate filename in SHA256SUMS: {filename}")
    sums_map[filename] = digest

if not sums_map:
    raise SystemExit("SHA256SUMS contains no entries")

# Verify every SHA256SUMS entry on disk
for filename, expected_digest in sums_map.items():
    artifact = rel_dir / filename
    if not artifact.is_file():
        raise SystemExit(f"Missing artifact listed in SHA256SUMS: {filename}")
    actual_digest = sha256_file(artifact)
    if actual_digest != expected_digest:
        raise SystemExit(
            f"SHA-256 mismatch for {filename}: expected {expected_digest}, got {actual_digest}"
        )

# Verify release-manifest.json artifacts match SHA256SUMS & embedded BUILD_MANIFEST.json
manifest_version = manifest.get("version")
manifest_commit = manifest.get("git_commit")
manifest_artifacts = manifest.get("artifacts", [])
manifest_names = {entry["name"] for entry in manifest_artifacts}

if manifest_names != set(sums_map.keys()):
    raise SystemExit(
        f"Artifact set mismatch between SHA256SUMS ({sorted(sums_map)}) and release-manifest.json ({sorted(manifest_names)})"
    )

for entry in manifest_artifacts:
    name = entry["name"]
    artifact = rel_dir / name
    if entry["sha256"] != sums_map[name]:
        raise SystemExit(f"Manifest digest mismatch for {name}")
    if entry["size"] != artifact.stat().st_size:
        raise SystemExit(f"Manifest size mismatch for {name}")
    if name.endswith(".tar.gz"):
        with tarfile.open(artifact, "r:gz") as tf:
            try:
                member = tf.getmember("harness/BUILD_MANIFEST.json")
            except KeyError:
                raise SystemExit(f"{name} is missing harness/BUILD_MANIFEST.json") from None
            fh = tf.extractfile(member)
            if fh is None:
                raise SystemExit(f"{name} has empty harness/BUILD_MANIFEST.json")
            raw = fh.read()
        bm_sha = hashlib.sha256(raw).hexdigest()
        if entry.get("build_manifest_sha256") != bm_sha:
            raise SystemExit(
                f"{name}: BUILD_MANIFEST.json digest mismatch (manifest={entry.get('build_manifest_sha256')}, actual={bm_sha})"
            )
        bm = json.loads(raw.decode("utf-8"))
        if bm.get("version") != manifest_version:
            raise SystemExit(
                f"{name}: BUILD_MANIFEST.json version {bm.get('version')!r} != release version {manifest_version!r}"
            )
        if bm.get("git_commit") != manifest_commit:
            raise SystemExit(
                f"{name}: BUILD_MANIFEST.json git_commit {bm.get('git_commit')!r} != release git_commit {manifest_commit!r}"
            )

print(
    f"Verified {len(sums_map)} release artifact(s) for harness v{manifest_version} (commit {manifest_commit[:12]})"
)
PY
