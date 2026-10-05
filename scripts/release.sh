#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.2.1}"
BUILD_NUMBER="${BUILD_NUMBER:-3}"

usage() {
    cat <<'USAGE'
Usage: scripts/release.sh [--version 0.2.1]

Build a universal app, ZIP, and DMG in dist/ without publishing them. Requires Xcode.
Environment: VERSION (default: 0.2.1), BUILD_NUMBER (default: 3).
Set SIGNING_IDENTITY to a Developer ID Application identity to sign.
Also set NOTARY_PROFILE to an existing notarytool Keychain profile to notarize.
Without these, output is ad-hoc signed and is not notarized by Apple.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -n "${NOTARY_PROFILE:-}" && ( -z "${SIGNING_IDENTITY:-}" || "$SIGNING_IDENTITY" == "-" ) ]]; then
    echo "NOTARY_PROFILE requires SIGNING_IDENTITY to name a Developer ID Application identity." >&2
    exit 1
fi

BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/build.sh" --universal --version "$VERSION"
APP="$ROOT/dist/Lacuna.app"
STEM="$ROOT/dist/Lacuna-$VERSION-universal"
STAGING="$(mktemp -d "$ROOT/dist/.lacuna-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/submit.zip"
    xcrun notarytool submit "$STAGING/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

rm -f "$STEM.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STEM.zip"
mkdir -p "$STAGING/dmg"
ditto "$APP" "$STAGING/dmg/Lacuna.app"
ln -s /Applications "$STAGING/dmg/Applications"
hdiutil create -volname Lacuna -srcfolder "$STAGING/dmg" -format UDZO -ov "$STEM.dmg"

if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$STEM.dmg"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$STEM.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$STEM.dmg"
    xcrun stapler validate "$STEM.dmg"
    echo "Created signed and notarized release archives."
else
    echo "Created release archives. They have not been notarized by Apple."
fi

(
    cd "$ROOT/dist"
    shasum -a 256 "Lacuna-$VERSION-universal.zip" "Lacuna-$VERSION-universal.dmg" > "Lacuna-$VERSION-universal.sha256"
)
echo "$STEM.zip"
echo "$STEM.dmg"
echo "$STEM.sha256"
