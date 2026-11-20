#!/bin/sh
# Build a native, relocatable hi + H daemon bundle; never installs or starts it.
set -eu
if [ "$#" != 1 ]; then
  echo 'Usage: scripts/build-bundle.sh /path/to/new/bundle' >&2
  exit 2
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
parent=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd -P)
name=$(basename -- "$1")
out="$parent/$name"
if [ "$name" = . ] || [ "$name" = .. ] || [ -e "$out" ] || [ -L "$out" ]; then
  echo "Bundle destination must not exist: $out" >&2
  exit 2
fi
case $(uname -s) in
  Darwin) tmp=/private/tmp ;;
  Linux) tmp=${TMPDIR:-/tmp} ;;
  *) echo 'Bundle builds are supported on macOS and Linux' >&2; exit 2 ;;
esac
if [ -z "${MIX_DEPS_PATH:-}" ]; then
  export MIX_DEPS_PATH="$root/deps"
fi
work=$(mktemp -d "$tmp/h-bundle.XXXXXX")
# Stage beside the destination so the finished directory is published by rename.
stage=$(mktemp -d "$parent/.h-bundle.XXXXXX") || { rmdir "$work"; exit 1; }
trap 'rm -rf -- "$work" "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export MIX_ENV=prod MIX_BUILD_PATH="$work/mix" CARGO_TARGET_DIR="$work/cargo"
cd "$root"
mix deps.get --only prod --check-locked
mix compile --warnings-as-errors
mix release harness --path "$stage/otp"
cargo build --locked --release --manifest-path clients/tui/Cargo.toml --bin hi
install -m 755 "$CARGO_TARGET_DIR/release/hi" "$stage/otp/bin/hi"
install -m 755 rel/h-daemon "$stage/otp/bin/h-daemon"
cp rel/README.md "$stage/otp/README.md"
# Ship the matching optional artifact without enabling it or copying any config.
export H_SOURCE="$root"
(cd extensions/multicodex; mix deps.get --only prod --check-locked; mix extension.build "$stage/otp/extensions/multicodex")
if [ "$(uname -s)" = Darwin ]; then
  python3 scripts/bundle-macos-libs.py "$stage/otp"
fi
# Do not publish a launcher that needs the build toolchain on PATH.
env -i PATH=/usr/bin:/bin HOME="$work" "$stage/otp/bin/h-daemon" --help
if [ -e "$out" ] || [ -L "$out" ]; then
  echo "Bundle destination appeared during build: $out" >&2
  exit 1
fi
mv "$stage/otp" "$out"
printf 'Bundle ready: %s\nStart with: %s/bin/hi daemon start\n' "$out" "$out"
