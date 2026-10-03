#!/bin/sh
# Builds build/EasyMarkdown.app (release, ad-hoc signed).
set -eu
cd "$(dirname "$0")"

swift build -c release

APP=build/EasyMarkdown.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$(swift build -c release --show-bin-path)/EasyMarkdown" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/web "$APP/Contents/Resources/"
cp Resources/icon/AppIcon.icns "$APP/Contents/Resources/"
cp bin/easymd "$APP/Contents/Resources/easymd"
chmod +x "$APP/Contents/Resources/easymd"

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
