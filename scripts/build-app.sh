#!/bin/zsh
# Builds Monitr.app (release, ad-hoc signed). Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/Monitr
APP=build/Monitr.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Monitr"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" \
  && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
[[ -z "${NOSTRIP:-}" ]] && strip -x "$APP/Contents/MacOS/Monitr"
codesign --force --sign - --options runtime "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Monitr 2>/dev/null || true
  rm -rf /Applications/Monitr.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Monitr.app"
fi
