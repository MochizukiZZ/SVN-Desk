#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/SVN Desk.app"
EXT="$APP/Contents/PlugIns/SVNFinderSync.appex"
mkdir -p "$EXT/Contents/MacOS"
xcrun swiftc -O -parse-as-library -application-extension -module-name SVNFinderSync \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework FinderSync \
  Sources/SVNCore/Models.swift Sources/SVNCore/FinderState.swift FinderExtension/FinderSync.swift \
  -Xlinker -e -Xlinker _NSExtensionMain -o "$EXT/Contents/MacOS/SVNFinderSync.new"
mv -f "$EXT/Contents/MacOS/SVNFinderSync.new" "$EXT/Contents/MacOS/SVNFinderSync"
cp FinderExtension/Info.plist "$EXT/Contents/Info.plist"
codesign --force --sign "${SVNDESK_SIGN_IDENTITY:--}" --entitlements FinderExtension/FinderSync.entitlements "$EXT"
