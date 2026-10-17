#!/bin/zsh
# Build "The New Zealand Story.app".
#   ./make-app.sh [path/to/Newzealand Story.adf]
# The ADF is needed at build time only to translate the original program code
# (tools/generate.sh). No graphics, sound, levels or text are put into the
# bundle: the app reads them from your ADF when it starts (File > Open Disk Image…).
set -e
ROOT=${0:A:h}
ADF=${1:-$ROOT/Newzealand Story.adf}
cd $ROOT
[ -f "$ADF" ] || { echo "ADF not found: $ADF"; exit 1; }
tools/generate.sh "$ADF"
swift build -c release --product NewZealandStory
APP="$ROOT/build/The New Zealand Story.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NewZealandStory "$APP/Contents/MacOS/NewZealandStory"
# icon: original pixel art drawn by tools/make-icon.swift (no game graphics)
swift tools/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>The New Zealand Story</string>
  <key>CFBundleDisplayName</key><string>The New Zealand Story</string>
  <key>CFBundleIdentifier</key><string>local.port.newzealandstory</string>
  <key>CFBundleExecutable</key><string>NewZealandStory</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.arcade-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Amiga Disk File</string>
    <key>CFBundleTypeExtensions</key><array><string>adf</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
  </dict></array>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" 2>/dev/null || true
# sanity check: no disk-derived data files in the bundle
if find "$APP" -type f ! -name NewZealandStory ! -name Info.plist ! -name CodeResources ! -name AppIcon.icns | grep -q .; then
  echo "unexpected files in bundle:"; find "$APP" -type f; exit 1
fi
echo "Built $APP"
