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
resources_dir="$contents/Resources"
mkdir -p "$macos_dir" "$resources_dir"

# 1. Info.plist & PkgInfo
sed "s/@VERSION@/$version/g" "$root/packaging/macos/Info.plist.in" > "$contents/Info.plist"
printf 'APPL????' > "$contents/PkgInfo"

# 2. AppIcon.icns
python3 "$root/packaging/macos/render-icon.py" "$resources_dir/AppIcon.icns"

# 3. Compile native Swift menu-bar launcher binary
swiftc \
  -O \
  -target "${swift_arch}-apple-macosx14.0" \
  -framework AppKit \
  -framework Foundation \
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
    xcrun notarytool submit "$artifact_path" \
      --key "$APPLE_NOTARY_KEY" \
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
