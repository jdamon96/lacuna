#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.2.1}"
BUILD_NUMBER="${BUILD_NUMBER:-3}"
UNIVERSAL=false

usage() {
    cat <<'USAGE'
Usage: scripts/build.sh [--universal] [--version 0.2.1]

Build dist/Lacuna.app for this Mac, or both Apple Silicon and Intel.
Environment: VERSION (default: 0.2.1), BUILD_NUMBER (default: 3),
SIGNING_IDENTITY (default: ad-hoc).
Requires Apple's Command Line Tools or Xcode, with Swift 5.9 or later.
Universal builds require the full Xcode installation.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal) UNIVERSAL=true; shift ;;
        --version)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || { echo "Lacuna builds require macOS." >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must use the form 0.2.1." >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be an integer." >&2; exit 1; }

export MACOSX_DEPLOYMENT_TARGET=13.0
BUILD_ARGS=(--configuration release --product Lacuna)
if [[ "$UNIVERSAL" == true ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
mkdir -p "$ROOT/dist"
STAGING="$(mktemp -d "$ROOT/dist/.lacuna-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Lacuna.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Lacuna" "$APP/Contents/MacOS/Lacuna"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

xcrun swift "$ROOT/scripts/generate-icon.swift" "$STAGING/Lacuna.iconset"
iconutil --convert icns "$STAGING/Lacuna.iconset" --output "$APP/Contents/Resources/Lacuna.icns"

if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
if [[ "$UNIVERSAL" == true ]]; then
    lipo "$APP/Contents/MacOS/Lacuna" -verify_arch arm64 x86_64
fi

rm -rf "$ROOT/dist/Lacuna.app"
mv "$APP" "$ROOT/dist/Lacuna.app"
echo "Built $ROOT/dist/Lacuna.app ($VERSION)."
