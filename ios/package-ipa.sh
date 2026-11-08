#!/bin/sh
# Packages a device build as an unsigned .ipa, for sideloading tools to sign
# (AltStore, SideStore, Sideloadly). Used by .github/workflows/ios.yml; run by
# ios/build.sh with IOS_PACKAGE=ipa. The binaries get an ad-hoc signature only.
set -e
OJK=$(cd "$(dirname "$0")/.." && pwd)
WS=$(dirname "$OJK")
GAME=${1:-jo}
if [ "$GAME" = ja ]; then
	B=$WS/build/device/openjk-ja
	EXE=openjk_sp.arm64 RENDERER=rdsp-vanilla_arm64.dylib GAMELIB=code/game/jagamearm64.dylib NAME=OpenJA
else
	B=$WS/build/device/openjk
	EXE=openjo_sp.arm64 RENDERER=rdjosp-vanilla_arm64.dylib GAMELIB=codeJK2/game/jospgamearm64.dylib NAME=OpenJO
fi
BUNDLE_ID=org.openjk.$(echo $NAME | tr A-Z a-z)
OUT=$WS/build/ipa
STAGE=$OUT/$NAME
APP=$STAGE/Payload/$NAME.app
rm -rf "$STAGE" "$OUT/$NAME-iOS-unsigned.ipa"
mkdir -p "$APP"
cp "$B/$EXE.app/$EXE" "$APP/"
cp "$B/code/rd-vanilla/$RENDERER" "$APP/"
cp "$B/$GAMELIB" "$APP/"
sed -e "s/org.openjk.openjo.spike/$BUNDLE_ID/" -e "s/iPhoneSimulator/iPhoneOS/" -e "s/openjo_sp.arm64/$EXE/" -e "s/>OpenJO</>$NAME</g" "$OJK/ios/Info.plist" > "$APP/Info.plist"
if [ -n "$IOS_VERSION" ]; then
	plutil -replace CFBundleShortVersionString -string "$IOS_VERSION" "$APP/Info.plist"
fi
if [ -n "$IOS_BUILD_NUMBER" ]; then
	plutil -replace CFBundleVersion -string "$IOS_BUILD_NUMBER" "$APP/Info.plist"
fi
plutil -lint "$APP/Info.plist"
codesign --force --sign - "$APP/$RENDERER"
codesign --force --sign - "$APP/$(basename "$GAMELIB")"
codesign --force --sign - "$APP"
(cd "$STAGE" && zip -qry "$OUT/$NAME-iOS-unsigned.ipa" Payload)
echo "Built $OUT/$NAME-iOS-unsigned.ipa"
