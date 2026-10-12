#!/bin/sh
# Lays out ../build/sim/OpenJO.app (next to this checkout) from the Simulator
# build: the engine, the renderer and game dylibs (both loaded from the bundle
# root at runtime), the iOS Info.plist, and an ad-hoc signature.
set -e
OJK=$(cd "$(dirname "$0")/.." && pwd)
WS=$(dirname "$OJK")
# the game: jo (Jedi Outcast, OpenJO.app) or ja (Jedi Academy, OpenJA.app)
GAME=${1:-jo}
if [ "$GAME" = ja ]; then
	B=$WS/build/sim/openjk-ja
	APP=$WS/build/sim/OpenJA.app
	EXE=openjk_sp.arm64 RENDERER=rdsp-vanilla_arm64.dylib GAMELIB=code/game/jagamearm64.dylib NAME=OpenJA
else
	B=$WS/build/sim/openjk
	APP=$WS/build/sim/OpenJO.app
	EXE=openjo_sp.arm64 RENDERER=rdjosp-vanilla_arm64.dylib GAMELIB=codeJK2/game/jospgamearm64.dylib NAME=OpenJO
fi
rm -rf "$APP"
mkdir -p "$APP"
cp "$B/$EXE.app/$EXE" "$APP/"
cp "$B/code/rd-vanilla/$RENDERER" "$APP/"
cp "$B/$GAMELIB" "$APP/"
sed -e "s/openjo_sp.arm64/$EXE/" -e "s/>OpenJO</>$NAME</g" -e "s/org.openjk.openjo.spike/org.openjk.$(echo $NAME | tr A-Z a-z).spike/" "$OJK/ios/Info.plist" > "$APP/Info.plist"
codesign --force --sign - "$APP/$RENDERER"
codesign --force --sign - "$APP/$(basename "$GAMELIB")"
codesign --force --sign - "$APP"
echo "Built $APP"
