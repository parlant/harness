#!/bin/sh
# Download (or reuse from cache) the pinned Sparkle 2 release tarball, verify
# its SHA-256 digest, and extract Sparkle.framework into a target directory.
#
# Usage: scripts/fetch-sparkle.sh [output-dir]
#
# If [output-dir] is omitted, extracts into the cache directory and prints the
# path to Sparkle.framework on stdout.
#
# Optional environment variables:
#   H_SPARKLE_FRAMEWORK  Path to an existing Sparkle.framework (skips download)
#   H_SPARKLE_CACHE_DIR  Cache directory for the verified tarball + framework
#                        (defaults to ${TMPDIR:-/tmp}/h-sparkle-cache)
set -eu

SPARKLE_VERSION="2.10.1"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"

if [ -n "${H_SPARKLE_FRAMEWORK:-}" ]; then
  if [ ! -d "$H_SPARKLE_FRAMEWORK" ]; then
    echo "H_SPARKLE_FRAMEWORK does not exist: $H_SPARKLE_FRAMEWORK" >&2
    exit 1
  fi
  src_fw=$(CDPATH= cd -- "$H_SPARKLE_FRAMEWORK" && pwd -P)
else
  case "$(uname -s)" in
    Darwin) default_cache="/private/tmp/h-sparkle-cache" ;;
    *) default_cache="${TMPDIR:-/tmp}/h-sparkle-cache" ;;
  esac
  cache_dir="${H_SPARKLE_CACHE_DIR:-$default_cache}"
  mkdir -p "$cache_dir"
  tarball="$cache_dir/Sparkle-${SPARKLE_VERSION}.tar.xz"
  extract_dir="$cache_dir/Sparkle-${SPARKLE_VERSION}"
  src_fw="$extract_dir/Sparkle.framework"

  verify_sha256() {
    actual=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1")
    [ "$actual" = "$SPARKLE_SHA256" ]
  }

  if [ ! -f "$tarball" ] || ! verify_sha256 "$tarball"; then
    tmp_tar="${tarball}.tmp.$$"
    rm -f "$tmp_tar"
    echo "Downloading Sparkle ${SPARKLE_VERSION}..." >&2
    curl --fail --silent --show-error --location --retry 3 --output "$tmp_tar" "$SPARKLE_URL"
    if ! verify_sha256 "$tmp_tar"; then
      echo "SHA-256 mismatch for Sparkle-${SPARKLE_VERSION}.tar.xz" >&2
      rm -f "$tmp_tar"
      exit 1
    fi
    mv -f "$tmp_tar" "$tarball"
  fi

  if [ ! -d "$src_fw" ]; then
    tmp_extract="${extract_dir}.tmp.$$"
    rm -rf "$tmp_extract" "$extract_dir"
    mkdir -p "$tmp_extract"
    tar -xf "$tarball" -C "$tmp_extract" Sparkle.framework
    mv "$tmp_extract" "$extract_dir"
  fi
fi

if [ "$#" -ge 1 ]; then
  dest_dir="$1"
  mkdir -p "$dest_dir"
  rm -rf "$dest_dir/Sparkle.framework"
  # Use ditto on macOS (cp -a elsewhere) to preserve framework symlinks intact.
  if [ -x /usr/bin/ditto ]; then
    /usr/bin/ditto "$src_fw" "$dest_dir/Sparkle.framework"
  else
    cp -a "$src_fw" "$dest_dir/Sparkle.framework"
  fi
  echo "$(CDPATH= cd -- "$dest_dir" && pwd -P)/Sparkle.framework"
else
  echo "$src_fw"
fi
