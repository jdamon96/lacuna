#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lacuna-highlight-panel.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Compile the production view and its only Core dependency without a SwiftPM
# build, so this check also runs independently of packaging or signing.
xcrun swiftc -parse-as-library -emit-module -emit-object -module-name LacunaCore \
    -emit-module-path "$TEST_DIR/LacunaCore.swiftmodule" \
    "$ROOT/Sources/LacunaCore/SuggestionNavigation.swift" -o "$TEST_DIR/SuggestionNavigation.o"
xcrun swiftc -I "$TEST_DIR" "$TEST_DIR/SuggestionNavigation.o" \
    "$ROOT/Sources/Lacuna/FloatingPanel.swift" "$ROOT/scripts/tests/highlight-panel.swift" \
    -o "$TEST_DIR/highlight-panel"
"$TEST_DIR/highlight-panel"
