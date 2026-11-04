#!/bin/zsh
# Builds Monitr.app (release). Pass --install to copy it to /Applications.
# Signs with the Developer ID certificate when it is in the keychain (needed for the root
# helper); otherwise signs ad hoc and the helper stays unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${MONITR_SIGN_IDENTITY:-Developer ID Application: JORDAN MUNGUJAKISA (VZ87DND9MP)}"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"

swift build -c release --arch arm64 --product Monitr
swift build -c release --arch arm64 --product MonitrHelper
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP=build/Monitr.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/Monitr" "$APP/Contents/MacOS/Monitr"
cp "$BIN/MonitrHelper" "$APP/Contents/MacOS/MonitrHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/LaunchDaemons/me.jordanjakisa.monitr.helper.plist "$APP/Contents/Library/LaunchDaemons/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" \
  && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
if [[ -z "${NOSTRIP:-}" ]]; then
  strip -x "$APP/Contents/MacOS/Monitr" "$APP/Contents/MacOS/MonitrHelper"
fi

# Inside out: the helper first (with its own identifier), then the app.
codesign --force --sign "$IDENTITY" --options runtime --identifier me.jordanjakisa.monitr.helper \
  "$APP/Contents/MacOS/MonitrHelper"
codesign --force --sign "$IDENTITY" --options runtime "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1)), signed by: $IDENTITY"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Monitr 2>/dev/null || true
  rm -rf /Applications/Monitr.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Monitr.app"
fi
