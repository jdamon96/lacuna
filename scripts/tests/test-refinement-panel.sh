#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lacuna-refinement-panel.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun swiftc -parse-as-library -emit-module -emit-object -module-name LacunaCore \
    -emit-module-path "$TEST_DIR/LacunaCore.swiftmodule" \
    "$ROOT/Sources/LacunaCore/SuggestionNavigation.swift" -o "$TEST_DIR/SuggestionNavigation.o"
xcrun swiftc -I "$TEST_DIR" "$TEST_DIR/SuggestionNavigation.o" \
    "$ROOT/Sources/Lacuna/FloatingPanel.swift" "$ROOT/scripts/tests/refinement-panel.swift" \
    -o "$TEST_DIR/refinement-panel"
"$TEST_DIR/refinement-panel"
