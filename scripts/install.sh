#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for ARGUMENT in "$@"; do
    if [[ "$ARGUMENT" == "-h" || "$ARGUMENT" == "--help" ]]; then
        echo "Usage: scripts/install.sh [--universal] [--version 0.2.0]"
        echo "Build, install to ~/Applications, and open Lacuna."
        exit 0
    fi
done
"$ROOT/scripts/build.sh" "$@"
INSTALL_DIR="$HOME/Applications"
DESTINATION="$INSTALL_DIR/Lacuna.app"
mkdir -p "$INSTALL_DIR"

# Quit a running copy before replacing its bundle. No elevated privileges needed.
if pgrep -x Lacuna >/dev/null; then
    osascript -e 'tell application id "com.jdamon.lacuna" to quit'
    for _ in {1..50}; do
        pgrep -x Lacuna >/dev/null || break
        sleep 0.1
    done
    if pgrep -x Lacuna >/dev/null; then
        echo "Quit Lacuna, then run this script again." >&2
        exit 1
    fi
fi

STAGING="$(mktemp -d "$INSTALL_DIR/.lacuna-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$ROOT/dist/Lacuna.app" "$STAGING/Lacuna.app"
rm -rf "$DESTINATION"
mv "$STAGING/Lacuna.app" "$DESTINATION"
open "$DESTINATION"
echo "Installed and opened $DESTINATION."
