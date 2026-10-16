#!/usr/bin/env zsh
# 构建 release 并打包为 build/RyouToolbox.app
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
APP=build/RyouToolbox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$(swift build -c release --show-bin-path)/RyouToolbox" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Ryou Toolbox</string>
<key>CFBundleDisplayName</key><string>Ryou Toolbox</string>
<key>CFBundleIdentifier</key><string>dev.ryou.toolbox</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>RyouToolbox</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "✅ $APP"
