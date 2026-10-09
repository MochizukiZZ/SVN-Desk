#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/SVN Desk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SVNDesk "$APP/Contents/MacOS/SVNDesk.new"
mv -f "$APP/Contents/MacOS/SVNDesk.new" "$APP/Contents/MacOS/SVNDesk"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SVNDesk</string>
<key>CFBundleIdentifier</key><string>net.wologic.svndesk</string>
<key>CFBundleName</key><string>SVN Desk</string>
<key>CFBundleDisplayName</key><string>SVN Desk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.4.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>net.wologic.svndesk.finder</string>
<key>CFBundleURLSchemes</key><array><string>svndesk</string></array>
</dict></array>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$APP/Contents/Resources"
./scripts/build-finder-extension.sh
codesign --force --sign "${SVNDESK_SIGN_IDENTITY:--}" "$APP"
print "已生成：$APP"
