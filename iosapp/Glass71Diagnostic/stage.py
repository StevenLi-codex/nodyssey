from pathlib import Path
import shutil,re,hashlib,json,os,subprocess
repo=Path.cwd(); stage=Path(os.environ['RUNNER_TEMP'])/'Glass71'; stage.mkdir(parents=True,exist_ok=True)
for path in ['iosapp/Nodyssey.xcodeproj','iosapp/NativeCore']:
    shutil.copytree(repo/path,stage/path,dirs_exist_ok=True)
app=stage/'iosapp/Nodyssey'; (app/'Native').mkdir(parents=True,exist_ok=True)
base=repo/'iosapp/Nodyssey/Native'; hashes={}
files=[]
for module in ['Content','Editing','Rendering','Sharing','Foundation','Media']:
    files += [p for p in (base/module).glob('*.swift') if p.name not in ['NativeClient.swift','NativeMediaScreens.swift']]
for name in ['AccountProfileDirectory','AccountSelfProfileState','AccountAttendanceState','AccountActionState','AccountMutationState','AccountProfileDate','AccountAuthorQuickCard','AccountAuthorQuickCardState']:
    files.append(base/'Account'/(name+'.swift'))
for name in ['SettingsThemeScreen','SettingsComponents','SettingsBehavior']:
    files.append(base/'Settings'/(name+'.swift'))
files.append(base/'Platform/NativeShare.swift')
for src in files:
    shutil.copy2(src,app/'Native'/src.name); hashes[str(src.relative_to(base))]=hashlib.sha256(src.read_bytes()).hexdigest()
src=base/'Account/NativeAccountScreens.swift'; s=src.read_text()
part=s[s.index('struct AccountInvalidRoute:'):s.index('struct AccountProfileHeader:')]+s[s.index('struct AccountProfileStatus:'):s.index('struct AccountSettingsScreen:')]
(app/'Native/NativeAccountScreens.swift').write_text('import SwiftUI\nimport NodysseyNativeCore\n'+part)
hashes['Account/NativeAccountScreens.swift']=hashlib.sha256(src.read_bytes()).hexdigest()
hashes['Account/NativeAccountScreens.swift:extracted']=hashlib.sha256(part.encode()).hexdigest()
for src in (repo/'iosapp/NativeCore/Sources').rglob('*.swift'): hashes[str(src.relative_to(repo))]=hashlib.sha256(src.read_bytes()).hexdigest()
for src in base.rglob('*.strings'):
    target=app/'Native'/src.parent.name/src.name; target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,target)
for src in base.rglob('*.xcstrings'):
    shutil.copy2(src,app/'Native'/src.name)
project=stage/'iosapp/Nodyssey.xcodeproj/project.pbxproj'; s=project.read_text().replace('A1000000000000000000002 /* AppIcon.icon in Resources */,','').replace('A1000000000000000000070 /* Build Kotlin framework */,','')
s=re.sub(r'\s*FRAMEWORK_SEARCH_PATHS = \([^;]+;', '',s); s=re.sub(r'\s*OTHER_LDFLAGS = \([^;]+;', '',s)
s=re.sub(r'\s*"EXCLUDED_ARCHS\[sdk=iphonesimulator\*\]" = x86_64;', '',s); project.write_text(s)
(app/'Info.plist').write_text('''<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string><key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string><key>CFBundleName</key><string>$(PRODUCT_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>71</string><key>CFBundleShortVersionString</key><string>1.0</string><key>UILaunchScreen</key><dict/></dict></plist>''')
shutil.copy2(repo/'iosapp/Glass71Diagnostic/Fixture.swift',app/'App.swift')
shutil.copy2(repo/'iosapp/Glass71Diagnostic/Geometry.swift',app/'Native/Geometry.swift')
test=stage/'iosapp/NativeNavigationUITests'; test.mkdir(exist_ok=True); shutil.copy2(repo/'iosapp/Glass71Diagnostic/Tests.swift',test/'NativeNavigationUITests.swift')
(stage/'sources.json').write_text(json.dumps({'sourceCommit': subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(), 'baseline':'415a21d90e81029ea38fc82e1c6a1aefd62c54a8','files':hashes,'boundaries':['Synthetic Kotlin/network NativeTransport','No remote images or external browser; fixture text only','Real Root/Feed/Search/Notifications/Profile/PostDetail/Reply and observers']},indent=2))
print(stage)
