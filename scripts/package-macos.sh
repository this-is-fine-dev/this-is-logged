#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
BUILD_ROOT="$PROJECT_ROOT/.build/native-package"
APP="$BUILD_ROOT/This Is Logged.app"
CONTENTS="$APP/Contents"
DIST="$PROJECT_ROOT/dist"
DMG="$DIST/This Is Logged.dmg"
MODULE_CACHE="$PROJECT_ROOT/.build/ModuleCache"
SDK_PATH=${SDKROOT:-$(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -type d -name 'MacOSX[0-9]*.sdk' | sort -V | head -1)}
SPARKLE_FRAMEWORK="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
LATEST_TAG=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
VERSION=${LATEST_TAG#v}
PLIST_VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PROJECT_ROOT/macos/Info.plist")
if [[ -z "$VERSION" ]]; then
  VERSION="$PLIST_VERSION"
elif [[ "$PLIST_VERSION" != "$VERSION" && ( $(git -C "$PROJECT_ROOT" rev-parse HEAD) != $(git -C "$PROJECT_ROOT" rev-list -n 1 "$LATEST_TAG") || -n $(git -C "$PROJECT_ROOT" status --porcelain) ) ]]; then
  VERSION="${VERSION%.*}.$((${VERSION##*.} + 1))"
fi
BUILD_VERSION="1$VERSION"
UPDATE_ZIP="$DIST/This-Is-Logged-$VERSION.zip"

env SDKROOT="$SDK_PATH" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swift build --disable-sandbox --disable-keychain -c release --product ThisIsLogged --package-path "$PROJECT_ROOT"
BIN_PATH=$(env SDKROOT="$SDK_PATH" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swift build --disable-sandbox --disable-keychain -c release --show-bin-path --package-path "$PROJECT_ROOT")

rm -rf "$BUILD_ROOT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" "$DIST"
cp "$BIN_PATH/ThisIsLogged" "$CONTENTS/MacOS/ThisIsLogged"
cp "$PROJECT_ROOT/macos/Info.plist" "$CONTENTS/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$CONTENTS/Info.plist"
cp "$PROJECT_ROOT/macos/AppIcon.icns" "$PROJECT_ROOT/macos/AppIcon.png" "$CONTENTS/Resources/"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"

SIGN_IDENTITY=${MACOS_SIGN_IDENTITY:--}
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
"$CONTENTS/MacOS/ThisIsLogged" --selfcheck

rm -f "$UPDATE_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATE_ZIP"

ln -s /Applications "$BUILD_ROOT/Applications"
rm -f "$DMG"
hdiutil create -volname "This Is Logged" -srcfolder "$BUILD_ROOT" -ov -format UDZO "$DMG"
echo "$DMG"
echo "$UPDATE_ZIP"
