#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--skip-build" ]]; then
    ./scripts/build-app.sh
fi
APP="$PWD/dist/SVN Desk.app"
codesign --verify --deep --strict "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
STAGE=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/SVN Desk.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'TEXT'
将 SVN Desk 拖入 Applications 安装。
运行环境：Apple Silicon Mac，macOS 13 或以上。
需要本机安装 Subversion：brew install subversion
TEXT
NAME="SVNDesk-${VERSION}-arm64.dmg"
hdiutil create -volname "SVN Desk" -srcfolder "$STAGE" -format UDZO -ov "$PWD/.build/$NAME"
mv -f "$PWD/.build/$NAME" "$PWD/dist/$NAME"
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")
print "已打包：$PWD/dist/$NAME"
