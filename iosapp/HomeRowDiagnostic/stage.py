from pathlib import Path
import shutil,re,hashlib,json,os
repo=Path.cwd(); stage=Path(os.environ['RUNNER_TEMP'])/'HomeRow'; stage.mkdir(exist_ok=True)
for path in ['iosapp/Nodyssey.xcodeproj','iosapp/NativeCore']:
    shutil.copytree(repo/path,stage/path,dirs_exist_ok=True)
app=stage/'iosapp/Nodyssey'; (app/'Native').mkdir(parents=True,exist_ok=True)
files=['Content/ContentCommon.swift','Content/ContentFeed.swift','Content/ContentState.swift','Content/ContentCommand.swift','Content/ContentPreferences.swift','Content/ContentNotifications.swift','Foundation/NativeStore.swift','Foundation/NativeAppModel.swift','Foundation/NativeRootView.swift','Foundation/NativeDestination.swift','Foundation/NativePresentation.swift','Foundation/NativeCommonViews.swift','Account/AccountProfileDirectory.swift','Account/AccountSelfProfileState.swift','Account/AccountAttendanceState.swift','Account/AccountActionState.swift','Account/AccountMutationState.swift','Account/AccountProfileDate.swift']
hashes={}
for name in files:
    src=repo/'iosapp/Nodyssey/Native'/name
    shutil.copy2(src,app/'Native'/src.name); hashes[name]=hashlib.sha256(src.read_bytes()).hexdigest()
src=repo/'iosapp/Nodyssey/Native/Account/NativeAccountScreens.swift'; s=src.read_text()
part=s[s.index('struct AccountInvalidRoute:'):s.index('struct AccountProfileHeader:')]+s[s.index('struct AccountProfileStatus:'):s.index('struct AccountSettingsScreen:')]
(app/'Native/NativeAccountScreens.swift').write_text('import SwiftUI\nimport NodysseyNativeCore\n'+part)
hashes['Account/NativeAccountScreens.swift']=hashlib.sha256(src.read_bytes()).hexdigest()
hashes['Account/NativeAccountScreens.swift:extracted']=hashlib.sha256(part.encode()).hexdigest()
for src in (repo/'iosapp/NativeCore/Sources').rglob('*.swift'): hashes[str(src.relative_to(repo))]=hashlib.sha256(src.read_bytes()).hexdigest()
for sub in ['Content','Account','Foundation']:
    for src in (repo/'iosapp/Nodyssey/Native'/sub/'Resources').rglob('*.strings'):
        target=app/src.parent.name/src.name; target.parent.mkdir(exist_ok=True); shutil.copy2(src,target)
for src in (repo/'iosapp/Nodyssey').glob('*.lproj/*.strings'):
    target=app/src.parent.name/src.name; target.parent.mkdir(exist_ok=True); shutil.copy2(src,target)
project=stage/'iosapp/Nodyssey.xcodeproj/project.pbxproj'; s=project.read_text().replace('A1000000000000000000002 /* AppIcon.icon in Resources */,','').replace('A1000000000000000000070 /* Build Kotlin framework */,','')
s=re.sub(r'\s*FRAMEWORK_SEARCH_PATHS = \([^;]+;', '',s); s=re.sub(r'\s*OTHER_LDFLAGS = \([^;]+;', '',s); project.write_text(s)
(app/'Info.plist').write_text('''<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string><key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string><key>CFBundleName</key><string>$(PRODUCT_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>69</string><key>CFBundleShortVersionString</key><string>1.0</string><key>UILaunchScreen</key><dict/></dict></plist>''')
shutil.copy2(repo/'iosapp/HomeRowDiagnostic/Fixture.swift',app/'App.swift')
test=stage/'iosapp/NativeNavigationUITests'; test.mkdir(exist_ok=True); shutil.copy2(repo/'iosapp/HomeRowDiagnostic/Tests.swift',test/'NativeNavigationUITests.swift')
(stage/'sources.json').write_text(json.dumps(hashes,indent=2)); print(stage)
