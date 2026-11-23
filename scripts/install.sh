#!/bin/sh
# Install a signed Harness (H) release bundle for macOS or Linux.
# Overrides: H_VERSION, H_RELEASE_URL, H_PREFIX, H_BIN_DIR, H_DATA_DIR, H_SIGNER_PUBKEY
set -eu

SIGNER_KEY="${H_SIGNER_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKsOhoxQkZ8pxWeObg2Q10fJ/Gcg0uL4pt1Oy/3vgLuN}"
VERSION="${H_VERSION:-latest}"
PREFIX="${H_PREFIX:-$HOME/.local/opt/harness}"
BIN_DIR="${H_BIN_DIR:-}"
DATA_DIR="${H_DATA_DIR:-$HOME/.local/share/h}"
INSTALL_SERVICE=0

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)  [ "$#" -ge 2 ] || die "--version requires a value";  VERSION="$2";  shift 2 ;;
    --prefix)   [ "$#" -ge 2 ] || die "--prefix requires a value";   PREFIX="$2";   shift 2 ;;
    --bin-dir)  [ "$#" -ge 2 ] || die "--bin-dir requires a value";  BIN_DIR="$2";  shift 2 ;;
    --data-dir) [ "$#" -ge 2 ] || die "--data-dir requires a value"; DATA_DIR="$2"; shift 2 ;;
    --service)  INSTALL_SERVICE=1; shift ;;
    -h|--help)  printf 'Usage: install.sh [--version VER] [--prefix DIR] [--bin-dir DIR] [--data-dir DIR] [--service]\n'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

norm_dir() {
  d="$1"
  while [ "$d" != "/" ] && [ "${d%/}" != "$d" ]; do d="${d%/}"; done
  printf '%s' "$d"
}
path_has() {
  target="$(norm_dir "$1")"
  old_ifs="$IFS"; IFS=:
  for p in ${PATH:-}; do
    [ -n "$p" ] && [ "$(norm_dir "$p")" = "$target" ] && { IFS="$old_ifs"; return 0; }
  done
  IFS="$old_ifs"; return 1
}
dir_writable() { [ -d "$1" ] && [ -w "$1" ]; }
local_bin_usable() {
  dir_writable "$1" && return 0
  [ ! -e "$1" ] && { dir_writable "$HOME/.local" || { [ ! -e "$HOME/.local" ] && dir_writable "$HOME"; }; }
}
excluded_path_dir() {
  case "$1" in
    /*) ;; *) return 0 ;;
  esac
  case "$1" in
    /|/bin|/usr/bin|/sbin|/usr/sbin|/System/*|/Library/*|/var/run/*|*/.cargo/bin|*/Cellar/*|*/shims|*/shims/*|*/erts-*|*/node_modules/.bin) return 0 ;;
  esac
  [ "$1" = "$(norm_dir "$HOME/.bin")" ] && return 0
  return 1
}
select_bin_dir() {
  [ -n "$BIN_DIR" ] && { printf '%s' "$BIN_DIR"; return; }
  pref_list="${H_PREFERRED_BIN_DIRS:-/usr/local/bin:/opt/local/bin:/opt/homebrew/bin}"
  old_ifs="$IFS"; IFS=:
  for pref in $pref_list; do
    [ -n "$pref" ] || continue
    pref="$(norm_dir "$pref")"
    path_has "$pref" && dir_writable "$pref" && { IFS="$old_ifs"; printf '%s' "$pref"; return; }
  done
  IFS="$old_ifs"
  local_bin="$(norm_dir "$HOME/.local/bin")"
  path_has "$local_bin" && local_bin_usable "$local_bin" && { printf '%s' "$local_bin"; return; }
  old_ifs="$IFS"; IFS=:
  for raw in ${PATH:-}; do
    [ -n "$raw" ] || continue
    d="$(norm_dir "$raw")"
    excluded_path_dir "$d" && continue
    dir_writable "$d" && { IFS="$old_ifs"; printf '%s' "$d"; return; }
  done
  IFS="$old_ifs"
  home_bin="$(norm_dir "$HOME/.bin")"
  path_has "$home_bin" && dir_writable "$home_bin" && { printf '%s' "$home_bin"; return; }
  old_ifs="$IFS"; IFS=:
  for pref in $pref_list; do
    [ -n "$pref" ] || continue
    pref="$(norm_dir "$pref")"
    dir_writable "$pref" && { IFS="$old_ifs"; printf '%s' "$pref"; return; }
  done
  IFS="$old_ifs"
  dir_writable "$local_bin" && { printf '%s' "$local_bin"; return; }
  printf '%s' "$home_bin"
}
BIN_DIR="$(select_bin_dir)"

case "${H_OS:-$(uname -s)}" in
  Darwin|darwin) OS=darwin ;;
  Linux|linux)   OS=linux ;;
  *) die "unsupported OS: $(uname -s) (supported: macOS, Linux)" ;;
esac
case "${H_ARCH:-$(uname -m)}" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) die "unsupported architecture: $(uname -m) (supported: arm64, x86_64)" ;;
esac

if [ -n "${H_RELEASE_URL:-}" ]; then BASE_URL="${H_RELEASE_URL%/}"
elif [ "$VERSION" = "latest" ]; then BASE_URL="https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads"
else BASE_URL="https://gitlab.com/parlant-co/harness/-/releases/v${VERSION#v}/downloads"
fi

need tar; need ssh-keygen
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --proto '=https' --tlsv1.2 "$1" -o "$2"; }
  case "$BASE_URL" in http://127.0.0.1:*|http://localhost:*) fetch() { curl -fsSL "$1" -o "$2"; } ;; esac
elif command -v wget >/dev/null 2>&1; then fetch() { wget -qO "$2" "$1"; }
else die "curl or wget is required"
fi

if command -v sha256sum >/dev/null 2>&1; then sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else die "sha256sum or shasum is required"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/h-install.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

printf 'Fetching release manifest from %s\n' "$BASE_URL"
fetch "$BASE_URL/SHA256SUMS" "$TMP/SHA256SUMS" || die "failed to download SHA256SUMS"
fetch "$BASE_URL/SHA256SUMS.sig" "$TMP/SHA256SUMS.sig" || die "failed to download SHA256SUMS.sig"
printf 'bingboombam@parlant.xyz %s\n' "$SIGNER_KEY" > "$TMP/allowed_signers"
ssh-keygen -Y verify -f "$TMP/allowed_signers" -I bingboombam@parlant.xyz -n file \
  -s "$TMP/SHA256SUMS.sig" < "$TMP/SHA256SUMS" >/dev/null 2>&1 || die "SSH signature verification failed"

MATCH="$(awk -v s="-${OS}-${ARCH}.tar.gz" 'NF >= 2 { f=$2; sub(/^\*/, "", f); if (length(f) > length(s) && substr(f, length(f)-length(s)+1) == s) { print $1 " " f; exit } }' "$TMP/SHA256SUMS")"
[ -n "$MATCH" ] || die "no release artifact for ${OS}-${ARCH} in SHA256SUMS"
EXPECTED_SHA="${MATCH%% *}"; TARBALL="${MATCH#* }"
case "$TARBALL" in */*|*..*|""|-*) die "invalid artifact name: $TARBALL" ;; esac

printf 'Downloading %s...\n' "$TARBALL"
fetch "$BASE_URL/$TARBALL" "$TMP/$TARBALL" || die "failed to download $TARBALL"
[ "$(sha256_of "$TMP/$TARBALL")" = "$EXPECTED_SHA" ] || die "SHA-256 mismatch for $TARBALL"

mkdir -p "$TMP/extract" "$PREFIX/releases" "$BIN_DIR"
chmod 700 "$PREFIX" 2>/dev/null || true
tar -xzf "$TMP/$TARBALL" -C "$TMP/extract"
BUNDLE_SRC="$TMP/extract"
if [ ! -x "$BUNDLE_SRC/bin/hi" ]; then
  TOP="$(find "$TMP/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$TOP" ] && [ -x "$TOP/bin/hi" ] && BUNDLE_SRC="$TOP"
fi
[ -x "$BUNDLE_SRC/bin/hi" ] && [ -x "$BUNDLE_SRC/bin/h-daemon" ] && [ -f "$BUNDLE_SRC/releases/start_erl.data" ] \
  || die "downloaded archive is not a valid Harness bundle"

RELEASE_ID="${TARBALL%.tar.gz}-$(date -u +%Y%m%d%H%M%S)-$$"
DEST="$PREFIX/releases/$RELEASE_ID"; CURRENT="$PREFIX/current"
[ ! -e "$CURRENT" ] || [ -L "$CURRENT" ] || die "refusing to replace non-symlink $CURRENT"
for tool in hi hi-import; do
  [ ! -e "$BIN_DIR/$tool" ] || [ -L "$BIN_DIR/$tool" ] || die "refusing to replace non-symlink $BIN_DIR/$tool"
done

mv "$BUNDLE_SRC" "$DEST"
STAGE_LINK="$PREFIX/.current.$$"
ln -s "releases/$RELEASE_ID" "$STAGE_LINK"
mv -Tf "$STAGE_LINK" "$CURRENT" 2>/dev/null || { rm -f "$STAGE_LINK"; ln -sfn "releases/$RELEASE_ID" "$CURRENT"; }
ln -sfn "$CURRENT/bin/hi" "$BIN_DIR/hi"
[ -x "$DEST/bin/hi-import" ] && ln -sfn "$CURRENT/bin/hi-import" "$BIN_DIR/hi-import"

printf 'Installed %s -> %s (linked in %s)\n' "$RELEASE_ID" "$CURRENT" "$BIN_DIR"
if [ "$INSTALL_SERVICE" = 1 ]; then
  mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
  if [ "$OS" = "darwin" ]; then
    if "$CURRENT/bin/hi" daemon check-service --data-dir "$DATA_DIR" >/dev/null 2>&1; then
      H_DATA_DIR="$DATA_DIR" "$CURRENT/bin/hi" daemon restart-service
    else
      H_DATA_DIR="$DATA_DIR" "$CURRENT/bin/hi" daemon install-service --launcher "$CURRENT/bin/h-daemon"
    fi
  else
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$UNIT_DIR"
    printf '[Unit]\nDescription=Harness (H) Daemon\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart="%s" --data-dir "%s"\nWorkingDirectory=%s\nRestart=on-failure\nRestartSec=5\nTimeoutStopSec=660\n\n[Install]\nWantedBy=default.target\n' \
      "$CURRENT/bin/h-daemon" "$DATA_DIR" "$DATA_DIR" > "$UNIT_DIR/harness-daemon.service"
    chmod 600 "$UNIT_DIR/harness-daemon.service"
    systemctl --user daemon-reload && systemctl --user enable harness-daemon.service && systemctl --user restart harness-daemon.service
  fi
fi
path_has "$BIN_DIR" || printf 'Add %s to PATH in your shell profile, then run: hi\n' "$BIN_DIR"
