#!/bin/bash
# Builds build/Auxilius.app with the Command Line Tools alone; Xcode is not needed.
#   --install  also copies it to /Applications, where chat clients can rely on its path
#   --dmg      also packs it into build/Auxilius.dmg, with an Applications link to drag it onto
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Auxilius.app
DMG=build/Auxilius.dmg

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Auxilius "$APP/Contents/MacOS/Auxilius"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ "$APP/Contents/Resources/"
# Ad-hoc signature: enough for the camera permission prompt on this Mac, not for distribution.
codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
    --install)
        rm -rf /Applications/Auxilius.app
        cp -R "$APP" /Applications/Auxilius.app
        echo "Installed /Applications/Auxilius.app"
        ;;
    --dmg)
        STAGING=$(mktemp -d)
        cp -R "$APP" "$STAGING/"
        ln -s /Applications "$STAGING/Applications"
        rm -f "$DMG"
        hdiutil create -volname Auxilius -srcfolder "$STAGING" -format UDZO -quiet "$DMG"
        rm -rf "$STAGING"
        echo "Packed $DMG"
        ;;
esac
