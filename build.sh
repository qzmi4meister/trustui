#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$(pwd)/build/TrustUI.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    Sources/TrustUI.swift Sources/Localization.swift Sources/GuideView.swift -o "$APP/Contents/MacOS/TrustUI"
cp Sources/backend.py "$APP/Contents/Resources/backend.py"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TrustUI</string>
<key>CFBundleIdentifier</key><string>local.trustui.app</string>
<key>CFBundleName</key><string>TrustUI</string>
<key>CFBundleDisplayName</key><string>TrustUI</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/TrustUI-0.1.0-$(uname -m).zip"
echo "Built $APP"
