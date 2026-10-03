#!/bin/sh
# Builds and installs EasyMarkdown.app and links the `easymd` command.
#   APP_DIR  where the app goes   (default: /Applications)
#   BIN_DIR  where easymd goes    (default: ~/.local/bin)
set -eu
cd "$(dirname "$0")"

APP_DIR=${APP_DIR:-/Applications}
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}

./build.sh

rm -rf "$APP_DIR/EasyMarkdown.app"
cp -R build/EasyMarkdown.app "$APP_DIR/"
# Don't leave a second copy around for Spotlight/Launchpad to list.
rm -rf build/EasyMarkdown.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR/EasyMarkdown.app"

mkdir -p "$BIN_DIR"
ln -sf "$APP_DIR/EasyMarkdown.app/Contents/Resources/easymd" "$BIN_DIR/easymd"

echo "Installed $APP_DIR/EasyMarkdown.app"
echo "Linked    $BIN_DIR/easymd"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH" ;;
esac
