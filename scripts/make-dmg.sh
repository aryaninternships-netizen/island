#!/bin/zsh
# build/Island.app -> dist/Island-<version>.dmg with an Applications shortcut to drag onto.
# Run ./build.sh first. With a Developer ID in .local.env, set NOTARY_PROFILE (a profile saved with
# `xcrun notarytool store-credentials`) to notarize and staple too.
set -e
cd "${0:A:h}/.."
[[ -z $PUBLIC && -f .local.env ]] && source .local.env   # PUBLIC=1: the release build
APP=build/Island.app
[[ -d $APP ]] || { echo "run ./build.sh first"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $APP/Contents/Info.plist)
mkdir -p dist
STAGE=$(mktemp -d)
cp -R $APP "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT=dist/Island-$VER.dmg
rm -f $OUT
hdiutil create -volname "Island $VER" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ $OUT >/dev/null
rm -rf "$STAGE"
if [[ -n $SIGN_ID && $SIGN_ID == Developer\ ID* ]]; then
  codesign --sign "$SIGN_ID" --timestamp $OUT
  if [[ -n $NOTARY_PROFILE ]]; then
    xcrun notarytool submit $OUT --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple $OUT
  fi
fi
echo "$OUT ($(du -h $OUT | cut -f1))"
