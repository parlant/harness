#!/bin/sh
# Upload signed release artifacts to the GitLab Generic Package Registry and
# create (or update) the GitLab Release with permanent public download links.
# Optionally mirrors the release assets to GitHub Releases when
# GITHUB_RELEASE_TOKEN is configured.
#
# Usage: scripts/ci/gitlab-release.sh <release-dir>
#
# Expected GitLab CI environment variables:
#   CI_API_V4_URL, CI_PROJECT_ID, CI_COMMIT_TAG, CI_JOB_TOKEN (or GITLAB_RELEASE_TOKEN)
# Optional:
#   GITHUB_RELEASE_TOKEN  GitHub PAT / token with contents:write
#   GITHUB_RELEASE_REPO   defaults to parlant/harness
set -eu

if [ "$#" != 1 ]; then
  echo 'Usage: scripts/ci/gitlab-release.sh <release-dir>' >&2
  exit 2
fi

rel_dir=$(CDPATH= cd -- "$1" && pwd -P)

: "${CI_API_V4_URL:?CI_API_V4_URL is required}"
: "${CI_PROJECT_ID:?CI_PROJECT_ID is required}"
: "${CI_COMMIT_TAG:?CI_COMMIT_TAG is required}"

version="${CI_COMMIT_TAG#v}"
pkg_name="harness"
pkg_base="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/${pkg_name}/${version}"

if [ -n "${GITLAB_RELEASE_TOKEN:-}" ]; then
  auth_header="PRIVATE-TOKEN: ${GITLAB_RELEASE_TOKEN}"
elif [ -n "${CI_JOB_TOKEN:-}" ]; then
  auth_header="JOB-TOKEN: ${CI_JOB_TOKEN}"
else
  echo "Neither GITLAB_RELEASE_TOKEN nor CI_JOB_TOKEN is set" >&2
  exit 1
fi

# Collect all publishable release files (artifacts + provenance/signatures)
files=$(python3 - "$rel_dir" <<'PY'
from pathlib import Path
import sys

rel_dir = Path(sys.argv[1])
SUFFIXES = (".tar.gz", ".dmg", ".zip", ".ez", ".sig")
EXACT = {"SHA256SUMS", "release-manifest.json"}
for p in sorted(rel_dir.iterdir(), key=lambda x: x.name):
    if p.is_file() and (p.name in EXACT or any(p.name.endswith(s) for s in SUFFIXES)):
        print(p.name)
PY
)

if [ -z "$files" ]; then
  echo "No release files found in $rel_dir" >&2
  exit 1
fi

echo "==> Uploading release files to GitLab Generic Package Registry (${pkg_name}/${version})"
for fname in $files; do
  echo "  uploading $fname"
  curl --fail --silent --show-error \
    --header "$auth_header" \
    --upload-file "$rel_dir/$fname" \
    "${pkg_base}/${fname}" >/dev/null
done

# Build GitLab Release payload JSON
payload=$(python3 - "$rel_dir" "$CI_COMMIT_TAG" "$pkg_base" <<'PY'
import json
from pathlib import Path
import sys

rel_dir = Path(sys.argv[1])
tag = sys.argv[2]
pkg_base = sys.argv[3]

manifest = json.loads((rel_dir / "release-manifest.json").read_text(encoding="utf-8"))
commit = manifest.get("git_commit", "")
version = manifest.get("version", tag.lstrip("v"))

SUFFIXES = (".tar.gz", ".dmg", ".zip", ".ez", ".sig")
EXACT = {"SHA256SUMS", "release-manifest.json"}
files = [
    p.name for p in sorted(rel_dir.iterdir(), key=lambda x: x.name)
    if p.is_file() and (p.name in EXACT or any(p.name.endswith(s) for s in SUFFIXES))
]

links = []
for name in files:
    link_type = "package" if any(name.endswith(s) for s in (".tar.gz", ".dmg", ".zip", ".ez")) else "other"
    links.append({
        "name": name,
        "url": f"{pkg_base}/{name}",
        "filepath": f"/{name}",
        "link_type": link_type,
    })

desc = (
    f"H (`:harness`) release `v{version}` built from commit `{commit}`.\n\n"
    "Verify downloads with OpenSSH using `packaging/keys/release-signers`:\n\n"
    "```sh\n"
    "ssh-keygen -Y verify -f packaging/keys/release-signers \\\n"
    "  -I l.rieder@gmail.com -n file -s SHA256SUMS.sig < SHA256SUMS\n"
    "sha256sum -c SHA256SUMS\n"
    "```\n"
)

print(json.dumps({
    "name": f"H v{version}",
    "tag_name": tag,
    "description": desc,
    "assets": {"links": links},
}))
PY
)

echo "==> Creating GitLab Release for ${CI_COMMIT_TAG}"
http_code=$(curl --silent --show-error --output /tmp/gl-release-resp.json --write-out '%{http_code}' \
  --request POST \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data "$payload" \
  "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/releases")

if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
  echo "GitLab Release API returned HTTP $http_code:" >&2
  cat /tmp/gl-release-resp.json >&2
  exit 1
fi
rm -f /tmp/gl-release-resp.json
echo "GitLab Release ${CI_COMMIT_TAG} published."

# Optional GitHub Releases mirror
if [ -n "${GITHUB_RELEASE_TOKEN:-}" ]; then
  gh_repo="${GITHUB_RELEASE_REPO:-parlant/harness}"
  echo "==> Mirroring release ${CI_COMMIT_TAG} to GitHub (${gh_repo})"
  gh_payload=$(python3 - "$rel_dir" "$CI_COMMIT_TAG" <<'PY'
import json
from pathlib import Path
import sys

rel_dir = Path(sys.argv[1])
tag = sys.argv[2]
manifest = json.loads((rel_dir / "release-manifest.json").read_text(encoding="utf-8"))
commit = manifest.get("git_commit", "")
version = manifest.get("version", tag.lstrip("v"))
print(json.dumps({
    "tag_name": tag,
    "target_commitish": commit or None,
    "name": f"H v{version}",
    "body": f"H (`:harness`) release `v{version}` built from commit `{commit}`.\n\nVerify with `scripts/verify-release.sh` or `ssh-keygen -Y verify` using `packaging/keys/release-signers`.",
    "draft": False,
    "prerelease": "-" in version,
}))
PY
  )

  gh_resp=$(curl --fail --silent --show-error \
    --request POST \
    --header "Authorization: Bearer ${GITHUB_RELEASE_TOKEN}" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --data "$gh_payload" \
    "https://api.github.com/repos/${gh_repo}/releases")

  upload_url=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["upload_url"].split("{", 1)[0])' "$gh_resp")

  for fname in $files; do
    echo "  mirroring $fname to GitHub"
    curl --fail --silent --show-error \
      --request POST \
      --header "Authorization: Bearer ${GITHUB_RELEASE_TOKEN}" \
      --header "Accept: application/vnd.github+json" \
      --header "Content-Type: application/octet-stream" \
      --data-binary "@$rel_dir/$fname" \
      "${upload_url}?name=${fname}" >/dev/null
  done
  echo "GitHub Release ${CI_COMMIT_TAG} mirrored."
fi
