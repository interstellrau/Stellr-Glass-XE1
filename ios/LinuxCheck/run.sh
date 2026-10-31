#!/usr/bin/env bash
# ios/LinuxCheck/run.sh - checks the iPhone app's Swift on Linux, without a Mac.
#
#   1. Type-checks the WHOLE app (GlassBridge/**/*.swift: Core, Link, Services, App, Views,
#      Intents) in Swift 5 mode against stand-in modules in Stubs/ (SwiftUI, MapKit,
#      Network, CoreLocation, Photos, UIKit, CoreImage, AppIntents, Combine). Their public
#      signatures copy the iOS 17+ SDK declarations from Apple's documentation JSON.
#   2. Builds and runs a simulation (main.swift): the real GlassServer, GlassLink and
#      MediaReceiver with a scriptable fake Network/Photos, playing Glass through pairing,
#      rejection, session replacement, hello timeout, uploads, queued cards, heartbeat,
#      Forget Glass and listener recovery. Takes about a minute (real timers).
#
# Limits, read before trusting a pass: the stubs are only as accurate as their copied
# signatures, SwiftUI's View is not @MainActor here (it is on the iOS 26 SDK), nothing is
# rendered, and `import CoreImage.CIFilterBuiltins` is stripped from a temporary copy
# (a Swift stub can't provide a Clang submodule). Xcode is still the first real compile.
# Tested with Swift 6.1.2 on Linux; not set up for macOS (the stubs would clash with the SDK).
#
# Environment: SWIFTC (default: swiftc on PATH). Exit 0 only if both parts pass.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../GlassBridge"
SWIFTC="${SWIFTC:-swiftc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"   # keep the simulation's UserDefaults out of the real home
mkdir -p "$HOME" "$WORK/mods" "$WORK/src"

stub() { # module name, then source files
  local m="$1"; shift
  "$SWIFTC" -swift-version 5 -parse-as-library -wmo -module-name "$m" -I "$WORK/mods" \
    -emit-module -emit-module-path "$WORK/mods/$m.swiftmodule" -c -o "$WORK/mods/$m.o" "$@" \
    > "$WORK/stub-$m.log" 2>&1 || { cat "$WORK/stub-$m.log"; echo "FAIL: stub $m"; exit 1; }
}

echo "== building stand-in modules"
for m in Combine Network CoreLocation Photos UIKit SwiftUI AppIntents CoreImage; do
  stub "$m" "$HERE/Stubs/$m.swift"
done
stub MapKit "$HERE/Stubs/MapKit.swift" "$HERE/Stubs/MapKitSwiftUI.swift"

echo "== 1. type-check the whole app (Swift 5 mode, minimal concurrency checking)"
cp -R "$APP" "$WORK/src/GlassBridge"
sed -i.bak '/^import CoreImage.CIFilterBuiltins$/d' "$WORK/src/GlassBridge/Views/ToolsTab.swift"
rm -f "$WORK/src/GlassBridge/Views/ToolsTab.swift.bak"
ALL=()
while IFS= read -r f; do ALL+=("$f"); done < <(find "$WORK/src/GlassBridge" -name '*.swift' | sort)
echo "   ${#ALL[@]} files"
"$SWIFTC" -swift-version 5 -strict-concurrency=minimal -parse-as-library -typecheck -I "$WORK/mods" \
  -module-name GlassBridge "${ALL[@]}" "$HERE/LinuxShims.swift" > "$WORK/typecheck.log" 2>&1 || true
sed "s#$WORK/src/##g" "$WORK/typecheck.log" | grep -E "(error|warning):" | grep -v '^ ' || true
if grep -q "error:" "$WORK/typecheck.log"; then
  sed "s#$WORK/src/##g" "$WORK/typecheck.log"
  echo "FAIL part 1: type errors"
  exit 1
fi
echo "PASS part 1 (any warnings above should only be the iOS 26 MKMapItem placemark deprecations)"

echo "== 2. simulation"
LOGIC=("$APP"/Core/*.swift "$APP/App/GBFormat.swift" "$APP"/Link/*.swift "$APP"/Services/*.swift)
"$SWIFTC" -swift-version 5 -I "$WORK/mods" -module-name GlassBridge -o "$WORK/glassbridge-sim" \
  "${LOGIC[@]}" "$HERE/LinuxShims.swift" "$HERE/main.swift" "$WORK"/mods/*.o > "$WORK/build.log" 2>&1 \
  || { cat "$WORK/build.log"; echo "FAIL: building the simulation"; exit 1; }
TMPDIR="$WORK" "$WORK/glassbridge-sim"
