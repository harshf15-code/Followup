#!/bin/zsh
# Builds build/Followup.app (universal: Apple Silicon + Intel).
#   ./build.sh install   also copies it to /Applications and launches it
#   ./build.sh dmg       also makes build/Followup-<version>.dmg for other Macs
set -e
cd "$(dirname "$0")"

swift build -c release --triple arm64-apple-macosx14.0
swift build -c release --triple x86_64-apple-macosx14.0

APP=build/Followup.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  .build/arm64-apple-macosx/release/Followup \
  .build/x86_64-apple-macosx/release/Followup \
  -output "$APP/Contents/MacOS/Followup"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature with an explicit designated requirement. Without -r, an
# ad-hoc app is identified by its code hash, which changes every build, so
# macOS forgets the Accessibility grant after each rebuild.
codesign --force --sign - --identifier com.harshsharma.followup \
  -r='designated => identifier "com.harshsharma.followup"' "$APP"
echo "Built $APP"

if [[ "$1" == "install" ]]; then
  pkill -x Followup 2>/dev/null || true
  rm -rf /Applications/Followup.app
  cp -R "$APP" /Applications/Followup.app
  open /Applications/Followup.app
  echo "Installed to /Applications/Followup.app"
fi

if [[ "$1" == "dmg" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
  STAGE=build/dmg
  DMG=build/Followup-$VERSION.dmg
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp Support/README-install.txt "$STAGE/Read me first.txt"
  hdiutil create -volname "Followup" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Made $DMG"
fi
