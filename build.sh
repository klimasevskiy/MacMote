#!/bin/zsh
# Builds a universal (arm64 + x86_64) release MacMote.app into ./build.
#   ./build.sh          build the app
#   ./build.sh zip      also pack build/MacMote.zip for a GitHub release
set -e
cd "$(dirname "$0")"
APP=build/MacMote.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -wmo -swift-version 5 -target $arch-apple-macos15.0 \
    -o build/MacMote-$arch Sources/*.swift
done
lipo -create build/MacMote-arm64 build/MacMote-x86_64 -output "$APP/Contents/MacOS/MacMote"
rm build/MacMote-arm64 build/MacMote-x86_64
strip -x "$APP/Contents/MacOS/MacMote"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "$1" == "zip" ]]; then
  rm -f build/MacMote.zip
  ditto -c -k --keepParent "$APP" build/MacMote.zip
  echo "Packed build/MacMote.zip"
fi
