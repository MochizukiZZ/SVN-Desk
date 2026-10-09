#!/usr/bin/env python3
"""创建独立验证应用；隔离偏好、URL 协议、Finder 状态和扩展标识。"""
from pathlib import Path
import plistlib
import shutil
import subprocess

project = Path(__file__).resolve().parent.parent
source = project / "dist" / "SVN Desk.app"
app = project / ".build" / "SVN Desk 验证.app"
if app.exists():
    raise SystemExit("验证应用已存在，请先退出并移除旧验证应用，再重新创建。")
shutil.copytree(source, app)
ext = app / "Contents" / "PlugIns" / "SVNFinderSync.appex"
for bundle, identifier, name in [
    (app, "net.wologic.svndesk.qa", "SVN Desk 验证"),
    (ext, "net.wologic.svndesk.qa.finder", "SVN Desk Finder 验证"),
]:
    file = bundle / "Contents" / "Info.plist"
    data = plistlib.loads(file.read_bytes())
    data.update(CFBundleIdentifier=identifier, CFBundleName=name, CFBundleDisplayName=name,
                SVNDeskFinderStoreName="SVN Desk QA", SVNDeskURLScheme="svndeskqa")
    if bundle == app:
        data["CFBundleURLTypes"] = [{"CFBundleURLName": identifier, "CFBundleURLSchemes": ["svndeskqa"]}]
    file.write_bytes(plistlib.dumps(data))
entitlements = plistlib.loads((project / "FinderExtension" / "FinderSync.entitlements").read_bytes())
entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] = ["/Library/Application Support/SVN Desk QA/Finder/"]
entitlement_file = project / ".build" / "qa-finder.entitlements"
entitlement_file.write_bytes(plistlib.dumps(entitlements))
subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlement_file), str(ext)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", str(app)], check=True)
subprocess.run(["pluginkit", "-a", str(ext)], check=True)
subprocess.run(["pluginkit", "-e", "use", "-i", "net.wologic.svndesk.qa.finder"], check=True)
subprocess.run(["open", str(app)], check=True)
print(app)
