#!/bin/sh
# Build, sign, optionally notarize, and package H.app (.dmg and .app.zip) from
# a tested macOS standalone H bundle.
#
# Usage: scripts/build-macos-app.sh <bundle-dir> <output-dir>
#
# Optional environment variables:
#   APPLE_CODESIGN_IDENTITY  Developer ID Application signing identity (defaults to ad-hoc `-`)
#   APPLE_NOTARY_PROFILE     keychain profile for `xcrun notarytool submit --wait`
#   APPLE_ID                 Apple ID (alternative to APPLE_NOTARY_PROFILE)
#   APPLE_TEAM_ID            Apple Team ID (with APPLE_ID)
#   APPLE_APP_PASSWORD       App-specific password (with APPLE_ID)
#   APPLE_NOTARY_KEY         Path to App Store Connect API .p8 key (alternative to APPLE_NOTARY_PROFILE)
#   APPLE_NOTARY_KEY_ID      App Store Connect API Key ID (with APPLE_NOTARY_KEY)
#   APPLE_NOTARY_ISSUER      App Store Connect API Issuer UUID (with APPLE_NOTARY_KEY)
#   H_SPARKLE_FEED_URL       Override SUFeedURL embedded in Info.plist
#                            (defaults to GitHub Releases latest appcast.xml)
#   H_SPARKLE_PUBLIC_ED_KEY  Override SUPublicEDKey embedded in Info.plist
#                            (defaults to Ed25519 key derived from packaging/keys/release-signers)
#   H_SPARKLE_FRAMEWORK      Path to an existing Sparkle.framework (skips fetch)
#   H_SKIP_APP_ZIP           Set to 1 to skip producing the .app.zip alongside .dmg
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo 'scripts/build-macos-app.sh must run on macOS' >&2
  exit 2
fi

if [ "$#" != 2 ]; then
  echo 'Usage: scripts/build-macos-app.sh <bundle-dir> <output-dir>' >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
bundle_dir=$(CDPATH= cd -- "$1" && pwd -P)
mkdir -p "$2"
out_dir=$(CDPATH= cd -- "$2" && pwd -P)

manifest="$bundle_dir/BUILD_MANIFEST.json"
if [ ! -f "$manifest" ]; then
  echo "Missing BUILD_MANIFEST.json in bundle: $bundle_dir" >&2
  exit 1
fi

read_manifest() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$manifest" "$1"
}

if [ ! -x "$bundle_dir/bin/hi-exec" ]; then
  echo 'Bundle is missing bin/hi-exec; rebuild the standalone bundle before packaging H.app.' >&2
  exit 1
fi

version=$(read_manifest version)
target=$(read_manifest target)

case "$target" in
  darwin-arm64) swift_arch=arm64 ;;
  darwin-x86_64) swift_arch=x86_64 ;;
  *) echo "Expected a darwin-* bundle, got target: $target" >&2; exit 2 ;;
esac

work=$(mktemp -d /private/tmp/h-macos-app.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

app="$work/H.app"
contents="$app/Contents"
macos_dir="$contents/MacOS"
frameworks_dir="$contents/Frameworks"
resources_dir="$contents/Resources"
mkdir -p "$macos_dir" "$frameworks_dir" "$resources_dir"

# 0. Fetch & embed Sparkle 2 framework
sparkle_fw=$("$root/scripts/fetch-sparkle.sh" "$frameworks_dir")

# Derive default Sparkle EdDSA public key (raw 32-byte Ed25519 key in base64)
# directly from packaging/keys/release-signers so Sparkle verifies updates with
# the same official release Ed25519 keypair used for SHA256SUMS.sig.
sparkle_feed_url="${H_SPARKLE_FEED_URL:-https://github.com/parlant/harness/releases/latest/download/appcast.xml}"
if [ -n "${H_SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  sparkle_public_ed_key="$H_SPARKLE_PUBLIC_ED_KEY"
else
  sparkle_public_ed_key=$(python3 - "$root/packaging/keys/release-signers" <<'PY'
import base64, struct, sys

for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    for i, tok in enumerate(parts):
        if tok == "ssh-ed25519" and i + 1 < len(parts):
            blob = base64.b64decode(parts[i + 1])
            n = struct.unpack(">I", blob[:4])[0]
            p = 4 + n
            n2 = struct.unpack(">I", blob[p:p + 4])[0]
            pk = blob[p + 4:p + 4 + n2]
            if len(pk) == 32:
                print(base64.b64encode(pk).decode("ascii"))
                sys.exit(0)
raise SystemExit("No ssh-ed25519 public key found in release-signers")
PY
  )
fi

# 1. Info.plist & PkgInfo
python3 - "$root/packaging/macos/Info.plist.in" "$contents/Info.plist" \
  "$version" "$sparkle_feed_url" "$sparkle_public_ed_key" <<'PY'
import sys
from xml.sax.saxutils import escape

src, dst, version, feed_url, pub_key = sys.argv[1:6]
text = open(src, encoding="utf-8").read()
text = (
    text.replace("@VERSION@", escape(version))
    .replace("@SPARKLE_FEED_URL@", escape(feed_url))
    .replace("@SPARKLE_PUBLIC_ED_KEY@", escape(pub_key))
)
open(dst, "w", encoding="utf-8").write(text)
PY
printf 'APPL????' > "$contents/PkgInfo"

# 2. AppIcon.icns
python3 "$root/packaging/macos/render-icon.py" "$resources_dir/AppIcon.icns"

# 3. Compile native Swift menu-bar launcher binary linked against embedded Sparkle.framework
swiftc \
  -O \
  -target "${swift_arch}-apple-macosx14.0" \
  -F "$frameworks_dir" \
  -framework AppKit \
  -framework Foundation \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$root/packaging/macos/HApp.swift" \
  -o "$macos_dir/HApp"
chmod 755 "$macos_dir/HApp"

# 4. Embed the complete relocatable standalone bundle
cp -a "$bundle_dir" "$resources_dir/harness"
# One real native helper at a version-independent app-relative path. The CLI
# bundle link resolves to this same signed executable, not a second identity.
mv "$resources_dir/harness/bin/hi-exec" "$macos_dir/hi-exec"
ln -s ../../../MacOS/hi-exec "$resources_dir/harness/bin/hi-exec"

# 5. Inside-out code signing (Mach-O binaries, NIFs, dylibs, then H.app)
identity="${APPLE_CODESIGN_IDENTITY:--}"
entitlements="$root/packaging/macos/entitlements.plist"

sign_macho() {
  path="$1"
  identifier="co.parlant.harness.$(basename "$path")"
  if [ "$identity" = "-" ]; then
    /usr/bin/codesign --force --identifier "$identifier" --sign - "$path"
  else
    /usr/bin/codesign --force --timestamp --options runtime \
      --identifier "$identifier" --entitlements "$entitlements" --sign "$identity" "$path"
  fi
}

python3 - "$resources_dir/harness" <<'PY' | while IFS= read -r bin_path; do
import sys
from pathlib import Path

root = Path(sys.argv[1])
MAGICS = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
matches = []
for p in sorted(root.rglob("*")):
    if p.is_symlink() or not p.is_file():
        continue
    try:
        with p.open("rb") as fh:
            if fh.read(4) in MAGICS:
                matches.append(p)
    except OSError:
        pass
# Sign dylibs/so files first, then executables.
matches.sort(key=lambda p: (0 if p.suffix in (".dylib", ".so") else 1, str(p)))
for p in matches:
    print(p)
PY
  sign_macho "$bin_path"
done
sign_macho "$macos_dir/hi-exec"

# Sign Sparkle.framework components inside-out (without H's JIT entitlements),
# preserving Sparkle's original bundle identifiers and hardened runtime.
sign_sparkle_item() {
  target_path="$1"
  if [ "$identity" = "-" ]; then
    /usr/bin/codesign --force --sign - "$target_path"
  else
    /usr/bin/codesign --force --timestamp --options runtime --sign "$identity" "$target_path"
  fi
}

sparkle_ver="$sparkle_fw/Versions/B"
for xpc in "$sparkle_ver"/XPCServices/*.xpc; do
  [ -e "$xpc" ] || continue
  sign_sparkle_item "$xpc"
done
if [ -e "$sparkle_ver/Autoupdate" ]; then
  sign_sparkle_item "$sparkle_ver/Autoupdate"
fi
if [ -d "$sparkle_ver/Updater.app" ]; then
  sign_sparkle_item "$sparkle_ver/Updater.app"
fi
sign_sparkle_item "$sparkle_fw"

if [ "$identity" = "-" ]; then
  /usr/bin/codesign --force --sign - "$app"
else
  /usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "$entitlements" --sign "$identity" "$app"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

# 6. Headless smoke check of the embedded launcher (zero touch on ~/.local/share/h)
env -i PATH=/usr/bin:/bin HOME="$work" "$macos_dir/hi-exec" daemon --help >/dev/null
# Exercise the signed native filesystem worker without a real account/store.
env -i PATH=/usr/bin:/bin HOME="$work" "$macos_dir/hi-exec" fs ls "$work" \
  | python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin)["ok"], list)'

# 7. Optional Apple notarization + stapling of H.app BEFORE packaging .app.zip and .dmg,
#    then package .app.zip and .dmg and notarize + staple the .dmg as well.
notarize_artifact() {
  artifact_path="$1"
  if [ -n "${APPLE_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$artifact_path" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
    return 0
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    xcrun notarytool submit "$artifact_path" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait
    return 0
  elif [ -n "${APPLE_NOTARY_KEY:-}" ] && [ -n "${APPLE_NOTARY_KEY_ID:-}" ] && [ -n "${APPLE_NOTARY_ISSUER:-}" ]; then
    notary_key_path="$APPLE_NOTARY_KEY"
    if [ ! -f "$notary_key_path" ]; then
      notary_key_path="$work/notary-key.p8"
      printf '%s\n' "$APPLE_NOTARY_KEY" > "$notary_key_path"
      chmod 600 "$notary_key_path"
    fi
    xcrun notarytool submit "$artifact_path" \
      --key "$notary_key_path" \
      --key-id "$APPLE_NOTARY_KEY_ID" \
      --issuer "$APPLE_NOTARY_ISSUER" \
      --wait
    return 0
  fi
  return 1
}

notary_configured=0
if [ -n "${APPLE_NOTARY_PROFILE:-}" ] || \
   { [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; } || \
   { [ -n "${APPLE_NOTARY_KEY:-}" ] && [ -n "${APPLE_NOTARY_KEY_ID:-}" ] && [ -n "${APPLE_NOTARY_ISSUER:-}" ]; }; then
  notary_configured=1
fi

if [ "$notary_configured" = "1" ]; then
  if [ "$identity" = "-" ]; then
    echo 'Apple notarization requires a Developer ID Application APPLE_CODESIGN_IDENTITY (not ad-hoc `-`).' >&2
    exit 1
  fi
  notary_zip="$work/H-notary.zip"
  /usr/bin/ditto -c -k --keepParent "$app" "$notary_zip"
  notarize_artifact "$notary_zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
fi

# 8. Package .app.zip (optional, default on) and .dmg
zip_path="$out_dir/H-v${version}-${target}.app.zip"
dmg_path="$out_dir/H-v${version}-${target}.dmg"

if [ "${H_SKIP_APP_ZIP:-0}" != "1" ]; then
  rm -f "$zip_path"
  /usr/bin/ditto -c -k --keepParent "$app" "$zip_path"
  echo "Packaged $zip_path"
fi

dmg_stage="$work/dmg-stage"
mkdir -p "$dmg_stage"
cp -a "$app" "$dmg_stage/H.app"
ln -s /Applications "$dmg_stage/Applications"

rm -f "$dmg_path"
/usr/bin/hdiutil create \
  -volname "H $version" \
  -srcfolder "$dmg_stage" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg_path" >/dev/null

if [ "$identity" != "-" ]; then
  /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg_path"
fi

if [ "$notary_configured" = "1" ]; then
  notarize_artifact "$dmg_path"
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
fi

# Copy H.app into output directory if requested via H_KEEP_APP=1
if [ "${H_KEEP_APP:-0}" = "1" ]; then
  rm -rf "$out_dir/H.app"
  cp -a "$app" "$out_dir/H.app"
fi

echo "Packaged $dmg_path"
