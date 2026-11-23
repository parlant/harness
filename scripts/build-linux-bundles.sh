#!/bin/sh
# Build and smoke-test Linux release tarballs (linux-arm64 and/or linux-x86_64)
# using Docker Buildx + Dockerfile.release, then optionally verify them in a
# clean minimal runtime container with no Elixir/Rust/Node installed.
#
# Usage: scripts/build-linux-bundles.sh <output-dir> [platform ...]
#   platforms default to: linux/arm64 linux/amd64
#
# Optional environment variables:
#   H_VERIFY_MINIMAL_IMAGE  runtime image for bare-container smoke test
#                           (default: debian:bookworm-slim)
#   H_SKIP_MINIMAL_VERIFY=1 skip the extra bare-container smoke check
#   H_GIT_COMMIT / H_GIT_TAG / H_RELEASE_VERSION  provenance overrides
set -eu

if [ "$#" -lt 1 ]; then
  echo 'Usage: scripts/build-linux-bundles.sh <output-dir> [linux/arm64 linux/amd64]' >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
mkdir -p "$1"
out_dir=$(CDPATH= cd -- "$1" && pwd -P)
shift

if [ "$#" -gt 0 ]; then
  platforms="$*"
else
  platforms="linux/arm64 linux/amd64"
fi

git_commit="${H_GIT_COMMIT:-$(git -C "$root" rev-parse HEAD)}"
git_tag="${H_GIT_TAG:-$(git -C "$root" describe --tags --exact-match 2>/dev/null || true)}"
release_version="${H_RELEASE_VERSION:-}"
minimal_image="${H_VERIFY_MINIMAL_IMAGE:-debian:bookworm-slim}"

host_arch=$(uname -m)

for plat in $platforms; do
  case "$plat" in
    linux/arm64) target=linux-arm64; plat_arch=arm64 ;;
    linux/amd64) target=linux-x86_64; plat_arch=x86_64 ;;
    *) echo "Unsupported platform: $plat (expected linux/arm64 or linux/amd64)" >&2; exit 2 ;;
  esac

  # Emulated linux/amd64 BEAM JIT under Apple Silicon Rosetta/QEMU requires
  # `+JMsingle true` (single-mapped JIT memory). Native runners need no flag.
  erl_flags="${H_BUILD_ERL_FLAGS:-}"
  if [ -z "$erl_flags" ] && [ "$plat_arch" = "x86_64" ] && { [ "$host_arch" = "arm64" ] || [ "$host_arch" = "aarch64" ]; }; then
    erl_flags="+JMsingle true"
  fi

  echo "==> Building and smoke-testing $target via docker buildx ($plat)"
  docker buildx build \
    --platform "$plat" \
    --file "$root/Dockerfile.release" \
    --target export \
    --build-arg "H_GIT_COMMIT=$git_commit" \
    --build-arg "H_GIT_TAG=$git_tag" \
    --build-arg "H_RELEASE_VERSION=$release_version" \
    --build-arg "H_BUILD_ERL_FLAGS=$erl_flags" \
    --output "type=local,dest=$out_dir" \
    "$root"

  if [ "${H_SKIP_MINIMAL_VERIFY:-0}" != "1" ]; then
    tarball=$(ls -1 "$out_dir"/harness-v*-"${target}.tar.gz" | tail -n 1)
    echo "==> Verifying $(basename "$tarball") in clean $minimal_image ($plat) with NO build tools"
    docker run --rm --platform "$plat" \
      -e "H_SMOKE_ERL_FLAGS=$erl_flags" \
      -v "$tarball:/tmp/release.tar.gz:ro" \
      -v "$root/scripts/smoke-bundle.py:/tmp/smoke/scripts/smoke-bundle.py:ro" \
      -v "$root/examples:/tmp/smoke/examples:ro" \
      "$minimal_image" \
      sh -eu -c '
        apt-get update -qq >/dev/null
        apt-get install -y -qq --no-install-recommends ca-certificates procps python3 >/dev/null
        mkdir -p /tmp/unpacked
        tar -xzf /tmp/release.tar.gz -C /tmp/unpacked
        python3 -B /tmp/smoke/scripts/smoke-bundle.py /tmp/unpacked/harness
      '
  fi
done

echo "Linux release artifacts ready in $out_dir:"
ls -lh "$out_dir"/harness-v*-linux-*.tar.gz
