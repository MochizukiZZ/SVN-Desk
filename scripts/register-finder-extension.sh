#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/SVN Desk.app"
EXT="$APP/Contents/PlugIns/SVNFinderSync.appex"
codesign --verify --deep --strict "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pluginkit -a "$EXT"
pluginkit -m -i net.wologic.svndesk.finder -v
print '已注册。请在 SVN Desk 设置中点击“管理 Finder 扩展”，启用 SVN Desk Finder。'
