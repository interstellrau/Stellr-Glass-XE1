#!/usr/bin/env bash
# tools/swift-check/run.sh - builds the iPhone app's Foundation-only Core with SwiftPM and
# checks it against the Python reference. Works on Linux and macOS (bash 3.2+).
#
#   tools/swift-check/run.sh
#
# Environment:
#   SWIFT    swift executable (default: swift on PATH)
#   PYTHON   python3 executable (default: python3)
#   GBCHECK_KEEP=1  keep the temporary work directory even when everything passes
#
# Steps:
#   0. copy ios/GlassBridge/Core/*.swift into Sources/gbcheck/Core (generated, gitignored)
#      and build gbcheck
#   1. python3 tools/make_test_stream.py write -> gbcheck parses the stream with every
#      read size and checks every frame against expected.json; then a differential fuzz
#      (parser_fuzz.py): Swift and gbproto must accept/reject the same random and mutated
#      header lines and decode accepted ones to equal values
#   2. gbcheck re-encodes every frame -> python3 tools/make_test_stream.py verify;
#      gbcheck emits one frame per Msg builder -> check_messages.py validates them with
#      tools/gbproto.py against PROTOCOL.md section 5
#   3. NavTracker on synthetic routes (depart, distances, prepare announce, off route,
#      reroute rate limit, arrival + 20 s hold, driving, reroute replace)
#   4. Maneuver.classify, WiFiQR.payload, pairing (PROTOCOL.md section 6), split reads,
#      limits, accessors, JSON layer and message builders
# Exit status: 0 when all four parts pass, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SWIFT="${SWIFT:-swift}"
PYTHON="${PYTHON:-python3}"
CORE_SRC="$REPO/ios/GlassBridge/Core"
CORE_DST="$HERE/Sources/gbcheck/Core"

fail() {
    echo ""
    echo "swift-check FAILED: $*"
    if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
        echo "Work files kept in $WORK"
    fi
    exit 1
}

if ! command -v "$SWIFT" >/dev/null 2>&1; then
    fail "'$SWIFT' not found. Install Swift (or Xcode) or set SWIFT=/path/to/swift."
fi
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    fail "'$PYTHON' not found. Set PYTHON=/path/to/python3."
fi

ls "$CORE_SRC"/*.swift >/dev/null 2>&1 || fail "no Swift files in $CORE_SRC"

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t gbcheck)" || fail "mktemp failed"

echo "== swift-check: $("$SWIFT" --version 2>&1 | head -n 1)"
echo "== 0. copy Core and build gbcheck"
rm -rf "$CORE_DST"
mkdir -p "$CORE_DST" || fail "can't create $CORE_DST"
cp "$CORE_SRC"/*.swift "$CORE_DST"/ || fail "copying Core failed"
echo "   copied: $(cd "$CORE_DST" && ls *.swift | tr '\n' ' ')"

if ! "$SWIFT" build --package-path "$HERE" -c debug > "$WORK/build.log" 2>&1; then
    cat "$WORK/build.log"
    fail "swift build failed (step 0)"
fi
tail -n 3 "$WORK/build.log" | sed 's/^/   /'
if grep -q "warning:" "$WORK/build.log"; then
    echo "   build warnings:"
    grep "warning:" "$WORK/build.log" | sed 's/^/     /'
fi
BIN_DIR="$("$SWIFT" build --package-path "$HERE" -c debug --show-bin-path 2>/dev/null)" || fail "can't find the build directory"
GBCHECK="$BIN_DIR/gbcheck"
[ -x "$GBCHECK" ] || fail "gbcheck was not built at $GBCHECK"

echo ""
echo "== 1. parse the Python test stream"
"$PYTHON" "$REPO/tools/make_test_stream.py" write "$WORK/stream.bin" "$WORK/expected.json" \
    || fail "make_test_stream.py write failed (step 1)"
"$GBCHECK" parse "$WORK/stream.bin" "$WORK/expected.json" || fail "part 1: Swift parse of the Python stream"
"$PYTHON" "$HERE/parser_fuzz.py" write "$WORK/fuzz.json" || fail "part 1: parser_fuzz.py write"
"$GBCHECK" fuzz "$WORK/fuzz.json" "$WORK/fuzz-swift.json" || fail "part 1: Swift fuzz run"
"$PYTHON" "$HERE/parser_fuzz.py" compare "$WORK/fuzz.json" "$WORK/fuzz-swift.json" \
    || fail "part 1: Swift and Python header parsers disagree"

echo ""
echo "== 2. re-encode with Swift, verify with Python"
"$GBCHECK" reencode "$WORK/stream.bin" "$WORK/swift.bin" || fail "part 2: Swift re-encode"
"$PYTHON" "$REPO/tools/make_test_stream.py" verify "$WORK/swift.bin" "$WORK/expected.json" \
    || fail "part 2: Python verify of the Swift encoding"
"$GBCHECK" emit "$WORK/builders.bin" || fail "part 2: Swift builder frames"
"$PYTHON" "$HERE/check_messages.py" "$WORK/builders.bin" \
    || fail "part 2: Python check of the Swift message builders"

echo ""
echo "== 3. NavTracker"
"$GBCHECK" nav || fail "part 3: NavTracker"

echo ""
echo "== 4. classify, Wi-Fi QR, pairing, split reads, limits, builders"
"$GBCHECK" unit || fail "part 4: unit checks"

echo ""
echo "swift-check PASSED: all four parts"
if [ "${GBCHECK_KEEP:-0}" = "1" ]; then
    echo "Work files kept in $WORK"
else
    rm -rf "$WORK"
fi
exit 0
