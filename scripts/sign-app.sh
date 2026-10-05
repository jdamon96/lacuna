#!/bin/bash
set -euo pipefail

[[ $# -eq 1 && -d "$1/Contents/MacOS" ]] || { echo "Usage: scripts/sign-app.sh path/to/Lacuna.app" >&2; exit 1; }
APP="$1"
IDENTITY="${SIGNING_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi

# Sign nested code from the inside out. In particular, retain the downloader's
# sandbox entitlements; --deep is appropriate for verification, not signing.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
VERSIONED="$FRAMEWORK/Versions/B"
for COMPONENT in \
    "$VERSIONED/XPCServices/Installer.xpc" \
    "$VERSIONED/XPCServices/Downloader.xpc" \
    "$VERSIONED/Autoupdate" \
    "$VERSIONED/Updater.app" \
    "$FRAMEWORK"; do
    [[ -e "$COMPONENT" ]] || { echo "Missing Sparkle component: $COMPONENT" >&2; exit 1; }
    # Sparkle's helper executables retain Hardened Runtime even in ad-hoc
    # previews. Only the ad-hoc host app omits it for library validation.
    codesign "${SIGN_ARGS[@]}" --options runtime --preserve-metadata=entitlements "$COMPONENT"
done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
