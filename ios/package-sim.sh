#!/bin/sh
# Lays out ../build/sim/OpenJO.app (next to this checkout) from the Simulator
# build: the engine, the renderer and game dylibs (both loaded from the bundle
# root at runtime), the iOS Info.plist, and an ad-hoc signature.
set -e
OJK=$(cd "$(dirname "$0")/.." && pwd)
WS=$(dirname "$OJK")
B=$WS/build/sim/openjk
APP=$WS/build/sim/OpenJO.app
rm -rf "$APP"
mkdir -p "$APP"
cp "$B/openjo_sp.arm64.app/openjo_sp.arm64" "$APP/"
cp "$B/code/rd-vanilla/rdjosp-vanilla_arm64.dylib" "$APP/"
cp "$B/codeJK2/game/jospgamearm64.dylib" "$APP/"
cp "$OJK/ios/Info.plist" "$APP/Info.plist"
codesign --force --sign - "$APP/rdjosp-vanilla_arm64.dylib"
codesign --force --sign - "$APP/jospgamearm64.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"
