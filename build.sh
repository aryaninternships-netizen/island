#!/bin/zsh
# Build Island.app with Command Line Tools only (no Xcode needed).
set -e
cd "${0:A:h}"
# Local, untracked overrides (bundle id, signing identity). See README › Build from source.
[[ -z $PUBLIC && -f .local.env ]] && source .local.env   # PUBLIC=1: the release build
BUNDLE_ID=${BUNDLE_ID:-app.island.notch}
ADAPTER=vendor/mediaremote-adapter
if [[ ! -d $ADAPTER/build/MediaRemoteAdapter.framework ]]; then
  [[ -d $ADAPTER ]] || git clone -q --depth 1 https://github.com/ungive/mediaremote-adapter $ADAPTER
  (cd $ADAPTER && mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build . >/dev/null)
fi
# Whisper (accurate after-meeting transcripts): whisper.cpp pinned, static, Metal shaders embedded.
WHISPER=vendor/whisper.cpp
if [[ ! -x $WHISPER/build/bin/whisper-cli ]]; then
  command -v cmake >/dev/null || { echo "needs cmake (brew install cmake)"; exit 1; }
  [[ -d $WHISPER ]] || git clone -q --depth 1 --branch v1.9.6 https://github.com/ggml-org/whisper.cpp $WHISPER
  (cd $WHISPER && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
     -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4 >/dev/null && cmake --build build -j 8 --target whisper-cli >/dev/null)
fi
swift build -c release 2>&1 | grep -vE "^\[|Compiling|Write|Planning|Building|Emitting"; [[ ${pipestatus[1]} == 0 ]] || { echo "build failed"; exit 1; }
BIN=$(swift build -c release --show-bin-path)/Island
[[ -x $BIN ]] || { echo "build failed"; exit 1; }
APP=build/Island.app
rm -rf $APP && mkdir -p $APP/Contents/{MacOS,Resources}
cp $BIN $APP/Contents/MacOS/Island
cp Resources/Info.plist $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
cp $ADAPTER/bin/mediaremote-adapter.pl $APP/Contents/Resources/
# Bruno's tiny brain (train with pup/train.py)
[[ -f pup/pup.bin ]] && cp pup/pup.bin pup/pup.json pup/pup.words.json $APP/Contents/Resources/
cp -R $ADAPTER/build/MediaRemoteAdapter.framework $APP/Contents/Resources/
cp $WHISPER/build/bin/whisper-cli $APP/Contents/Resources/
cp LICENSE THIRD_PARTY_NOTICES.md $APP/Contents/Resources/
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Contents/Resources/ && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" $APP/Contents/Info.plist
# Signing: SIGN_ID (e.g. "Developer ID Application: Name (TEAM)") from .local.env or the
# environment, optionally in SIGN_KEYCHAIN; otherwise ad-hoc (camera/mic grants reset each build).
if [[ -n $SIGN_ID ]]; then
  KCARGS=(); [[ -n $SIGN_KEYCHAIN ]] && KCARGS=(--keychain "$SIGN_KEYCHAIN")
  [[ -n $SIGN_KEYCHAIN && -n $SIGN_KEYCHAIN_PASS ]] && security unlock-keychain -p "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN" 2>/dev/null
  RT=(); [[ $SIGN_ID == Developer\ ID* ]] && RT=(--options runtime --timestamp --entitlements Resources/Island.entitlements)
  codesign --force "${RT[@]}" --sign "$SIGN_ID" "${KCARGS[@]}" $APP/Contents/Resources/whisper-cli
  codesign --force --deep "${RT[@]}" --sign "$SIGN_ID" "${KCARGS[@]}" $APP
else
  codesign --force --sign - $APP/Contents/Resources/whisper-cli
  codesign --force --deep --sign - $APP
fi
# Only the installed copy should own island:// (a second registered copy swallows URLs).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $APP 2>/dev/null || true
echo "built $APP"
