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
B=$WS/build/device/openjk
APP=$WS/build/device/OpenJO.app
rm -rf "$APP"
mkdir -p "$APP"
cp "$B/openjo_sp.arm64.app/openjo_sp.arm64" "$APP/"
cp "$B/code/rd-vanilla/rdjosp-vanilla_arm64.dylib" "$APP/"
cp "$B/codeJK2/game/jospgamearm64.dylib" "$APP/"
sed -e "s/org.openjk.openjo.spike/$IOS_BUNDLE_ID/" -e "s/iPhoneSimulator/iPhoneOS/" "$OJK/ios/Info.plist" > "$APP/Info.plist"
cp "$IOS_PROVISIONING_PROFILE" "$APP/embedded.mobileprovision"
# The app identifier uses the profile's App ID prefix, which on older teams
# isn't the team ID
PREFIX=$(security cms -D -i "$IOS_PROVISIONING_PROFILE" | plutil -extract ApplicationIdentifierPrefix.0 raw -)
ENT=$WS/build/device/OpenJO.entitlements
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>$PREFIX.$IOS_BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key><string>$IOS_TEAM_ID</string>
	<key>get-task-allow</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$IOS_CODESIGN_IDENTITY" --timestamp=none "$APP/rdjosp-vanilla_arm64.dylib"
codesign --force --sign "$IOS_CODESIGN_IDENTITY" --timestamp=none "$APP/jospgamearm64.dylib"
codesign --force --sign "$IOS_CODESIGN_IDENTITY" --timestamp=none --entitlements "$ENT" "$APP"
echo "Built $APP"
