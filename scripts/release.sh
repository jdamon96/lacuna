#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:-5}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.jdamon.lacuna.updates}"
RELEASE_REPOSITORY="${RELEASE_REPOSITORY:-jdamon96/lacuna}"

usage() {
    cat <<'USAGE'
Usage: scripts/release.sh [--version 0.3.0]

Build a universal app, ZIP, and DMG in dist/ without publishing them. Requires Xcode.
Environment: VERSION (default: 0.3.0), BUILD_NUMBER (default: 5).
Sparkle: SPARKLE_ACCOUNT (Keychain account; default: com.jdamon.lacuna.updates),
RELEASE_NOTES_FILE (optional plain-text notes), RELEASE_REPOSITORY (owner/repo).
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
SPARKLE_TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY="$("$SPARKLE_TOOLS/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || { echo "The Sparkle signing key does not match this app's verification key." >&2; exit 1; }
[[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "RELEASE_REPOSITORY must be owner/repo." >&2; exit 1; }
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

# Sign the final archive and metadata, after any notarization or stapling.
# This never exports the private key, which remains in the macOS Keychain.
UPDATE_SIGNATURE="$("$SPARKLE_TOOLS/sign_update" --account "$SPARKLE_ACCOUNT" -p "$STEM.zip")"
"$SPARKLE_TOOLS/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$STEM.zip" "$UPDATE_SIGNATURE"
APPCAST="$STAGING/appcast.xml"
if [[ -f "$ROOT/appcast.xml" ]]; then
    "$SPARKLE_TOOLS/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$ROOT/appcast.xml"
    cp "$ROOT/appcast.xml" "$APPCAST"
fi
NOTES="Lacuna $VERSION"
if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
    NOTES="$(cat "$RELEASE_NOTES_FILE")"
fi
python3 "$ROOT/scripts/update-appcast.py" --feed "$APPCAST" \
    --version "$VERSION" --build "$BUILD_NUMBER" \
    --url "https://github.com/$RELEASE_REPOSITORY/releases/download/v$VERSION/Lacuna-$VERSION-universal.zip" \
    --length "$(stat -f%z "$STEM.zip")" --signature "$UPDATE_SIGNATURE" \
    --minimum-system-version 13.0.0 --release-notes "$NOTES"
"$SPARKLE_TOOLS/sign_update" --account "$SPARKLE_ACCOUNT" "$APPCAST"
"$SPARKLE_TOOLS/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$APPCAST"
cp "$APPCAST" "$ROOT/dist/appcast.xml"

(
    cd "$ROOT/dist"
    shasum -a 256 "Lacuna-$VERSION-universal.zip" "Lacuna-$VERSION-universal.dmg" > "Lacuna-$VERSION-universal.sha256"
)
echo "$STEM.zip"
echo "$STEM.dmg"
echo "$STEM.sha256"
echo "$ROOT/dist/appcast.xml"
echo "Publish the release assets before copying dist/appcast.xml to appcast.xml and pushing the feed."
