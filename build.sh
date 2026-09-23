#!/bin/bash
# Builds MagicMouseShortcuts.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MagicMouseShortcuts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework IOKit -framework ServiceManagement \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/MagicMouseShortcuts"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MagicMouseShortcuts 2>/dev/null || true
  rm -rf /Applications/MagicMouseShortcuts.app
  cp -R "$APP" /Applications/
  open /Applications/MagicMouseShortcuts.app
  echo "Installed to /Applications/MagicMouseShortcuts.app"
fi
