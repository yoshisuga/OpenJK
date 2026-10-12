#!/bin/sh
# Lays out ../build/device/OpenJO.app (next to this checkout) for a real
# iPhone or iPad: engine, renderer and game dylibs (loaded from the bundle
# root), an iPhoneOS Info.plist, the provisioning profile, and a development
# signature (inside out). Needs:
#   IOS_CODESIGN_IDENTITY     e.g. "Apple Development: Name (XXXXXXXXXX)"
#   IOS_TEAM_ID               the certificate's team
#   IOS_BUNDLE_ID             covered by the profile
#   IOS_PROVISIONING_PROFILE  path to the .mobileprovision
set -e
: "${IOS_CODESIGN_IDENTITY:?}" "${IOS_TEAM_ID:?}" "${IOS_BUNDLE_ID:?}" "${IOS_PROVISIONING_PROFILE:?}"
OJK=$(cd "$(dirname "$0")/.." && pwd)
WS=$(dirname "$OJK")
# the game: jo (Jedi Outcast, OpenJO.app) or ja (Jedi Academy, OpenJA.app)
GAME=${1:-jo}
if [ "$GAME" = ja ]; then
	B=$WS/build/device/openjk-ja
	APP=$WS/build/device/OpenJA.app
	EXE=openjk_sp.arm64 RENDERER=rdsp-vanilla_arm64.dylib GAMELIB=code/game/jagamearm64.dylib NAME=OpenJA
else
	B=$WS/build/device/openjk
	APP=$WS/build/device/OpenJO.app
	EXE=openjo_sp.arm64 RENDERER=rdjosp-vanilla_arm64.dylib GAMELIB=codeJK2/game/jospgamearm64.dylib NAME=OpenJO
fi
rm -rf "$APP"
mkdir -p "$APP"
cp "$B/$EXE.app/$EXE" "$APP/"
cp "$B/code/rd-vanilla/$RENDERER" "$APP/"
cp "$B/$GAMELIB" "$APP/"
# Jedi Academy's bundle ID: IOS_BUNDLE_ID_JA, or IOS_BUNDLE_ID's last part
# made "openja" (com.example.openjo -> com.example.openja)
if [ "$GAME" = ja ]; then BUNDLE_ID=${IOS_BUNDLE_ID_JA:-${IOS_BUNDLE_ID%.*}.openja}; else BUNDLE_ID=$IOS_BUNDLE_ID; fi
sed -e "s/org.openjk.openjo.spike/$BUNDLE_ID/" -e "s/iPhoneSimulator/iPhoneOS/" -e "s/openjo_sp.arm64/$EXE/" -e "s/>OpenJO</>$NAME</g" "$OJK/ios/Info.plist" > "$APP/Info.plist"
cp "$IOS_PROVISIONING_PROFILE" "$APP/embedded.mobileprovision"
# The app identifier uses the profile's App ID prefix, which on older teams
# isn't the team ID
PREFIX=$(security cms -D -i "$IOS_PROVISIONING_PROFILE" | plutil -extract ApplicationIdentifierPrefix.0 raw -)
ENT=$WS/build/device/OpenJO.entitlements
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>$PREFIX.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key><string>$IOS_TEAM_ID</string>
	<key>get-task-allow</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$IOS_CODESIGN_IDENTITY" --timestamp=none "$APP/$RENDERER"
codesign --force --sign "$IOS_CODESIGN_IDENTITY" --timestamp=none "$APP/$(basename "$GAMELIB")"
codesign --force --sign "$IOS_CODESIGN_IDENTITY" --timestamp=none --entitlements "$ENT" "$APP"
echo "Built $APP"
