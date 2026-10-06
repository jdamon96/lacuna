#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lacuna-highlight-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun swiftc "$ROOT/Sources/Lacuna/NativeTextGeometry.swift" \
    "$ROOT/scripts/tests/highlight-geometry.swift" -o "$TEST_DIR/highlight-geometry"
"$TEST_DIR/highlight-geometry"
