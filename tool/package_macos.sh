#!/usr/bin/env bash
# Packages the release build of the macOS app as a .dmg.
#
#   tool/build_app.sh production
#   tool/package_macos.sh [--out dist]
#
# Signing and notarization run only when their credentials are provided:
#   FLORESTA_CODESIGN_IDENTITY  "Developer ID Application: Name (TEAMID)"
#   FLORESTA_NOTARY_PROFILE     a `xcrun notarytool store-credentials` profile
# Without an identity the app is ad-hoc signed and the .dmg is named
# "-unsigned": it opens only after the user overrides Gatekeeper, so it is
# for testing, never for distribution. Nothing is uploaded or published.
set -euo pipefail

die() { echo "package_macos: $*" >&2; exit 1; }
log() { echo "package_macos: $*" >&2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/dist"
[[ "${1:-}" == --out ]] && out="$2"
app="$root/build/macos/Build/Products/Release/Floresta.app"
[[ -d "$app" ]] || die "no release build at $app (run tool/build_app.sh first)"

version="$(awk '/^version:/ { split($2, v, "+"); print v[1] }' "$root/pubspec.yaml")"
arch="$(lipo -archs "$app/Contents/MacOS/Floresta")"
[[ "$arch" == *" "* ]] && arch=universal
identity="${FLORESTA_CODESIGN_IDENTITY:-}"
suffix=""
[[ -z "$identity" ]] && suffix="-unsigned"
name="Floresta-$version-macos-$arch$suffix"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Package only builds made by tool/build_app.sh production, which refuses
# development keys (a compiled define cannot be detected afterwards).
cp -R "$app" "$work/Floresta.app"
entitlements="$root/macos/Runner/Release.entitlements"
if [[ -n "$identity" ]]; then
  log "signing with $identity (hardened runtime)"
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$entitlements" --sign "$identity" "$work/Floresta.app"
else
  log "no FLORESTA_CODESIGN_IDENTITY: ad-hoc signature (not distributable)"
  codesign --force --deep --sign - --entitlements "$entitlements" "$work/Floresta.app"
fi
codesign --verify --deep --strict "$work/Floresta.app"
if [[ -n "${FLORESTA_NOTARY_PROFILE:-}" ]]; then
  [[ -n "$identity" ]] || die "notarization needs a Developer ID signature"
  log "notarizing the app (profile $FLORESTA_NOTARY_PROFILE)"
  ditto -c -k --keepParent "$work/Floresta.app" "$work/notarize.zip"
  xcrun notarytool submit "$work/notarize.zip" \
    --keychain-profile "$FLORESTA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$work/Floresta.app"
fi
# The in-app updater's package: the app alone, zipped with ditto
# so permissions, symlinks and the signature survive.
zip="$out/$name.zip"
rm -f "$zip"
ditto -c -k --keepParent "$work/Floresta.app" "$zip"

stage="$work/dmg"
mkdir -p "$stage"
cp -R "$work/Floresta.app" "$stage/"
ln -s /Applications "$stage/Applications"
cp "$root/LICENSE-MIT" "$root/LICENSE-APACHE" "$stage/"
dmg="$out/$name.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Floresta $version" -srcfolder "$stage" \
  -fs HFS+ -format UDZO "$dmg"
hdiutil verify -quiet "$dmg"
[[ -n "$identity" ]] && codesign --force --sign "$identity" --timestamp "$dmg"

if [[ -n "${FLORESTA_NOTARY_PROFILE:-}" ]]; then
  [[ -n "$identity" ]] || die "notarization needs a Developer ID signature"
  log "notarizing (profile $FLORESTA_NOTARY_PROFILE)"
  xcrun notarytool submit "$dmg" --keychain-profile "$FLORESTA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg"
else
  log "no FLORESTA_NOTARY_PROFILE: not notarized"
fi

shasum -a 256 "$dmg" | tee "$dmg.sha256"
shasum -a 256 "$zip" | tee "$zip.sha256"
log "wrote $dmg and $zip"
