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
# The icon is an Icon Composer file: actool turns it into the Liquid Glass asset (Assets.car)
# for macOS 26+ and a flat AppIcon.icns for older systems.
PARTIAL=$(mktemp -t monitr-icon)
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon --output-partial-info-plist "$PARTIAL" Resources/AppIcon.icon >/dev/null
rm -f "$PARTIAL"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
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
  # Leave only the installed copy: if LaunchServices also knows the build/ copy, macOS can tie
  # the background helper and login item to it instead of /Applications.
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -u "$PWD/$APP" >/dev/null 2>&1 || true
  rm -rf "$APP"
  rmdir build 2>/dev/null || true
  "$LSREG" -f /Applications/Monitr.app >/dev/null 2>&1 || true
  echo "Installed /Applications/Monitr.app"
fi
