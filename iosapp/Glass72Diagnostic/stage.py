from pathlib import Path
import shutil,re,hashlib,json,os,subprocess
repo=Path.cwd(); stage=Path(os.environ['RUNNER_TEMP'])/'Glass72'; stage.mkdir(parents=True,exist_ok=True)
source_commit=os.environ.get('DIAG_COMMIT','baede138d8bcef206ecc2d392c2038fd445633ec')
assert re.fullmatch(r'[0-9a-f]{40}',source_commit),source_commit
import tarfile,io
source_repo=Path(os.environ['RUNNER_TEMP'])/'PinnedSource'; source_repo.mkdir(exist_ok=True)
data=subprocess.check_output(['git','archive',source_commit,'iosapp/Nodyssey/Native','iosapp/NativeCore'])
with tarfile.open(fileobj=io.BytesIO(data)) as archive: archive.extractall(source_repo,filter='data')
for path in ['iosapp/Nodyssey.xcodeproj','iosapp/NativeCore']:
    shutil.copytree((source_repo if path == 'iosapp/NativeCore' else repo)/path,stage/path,dirs_exist_ok=True)
app=stage/'iosapp/Nodyssey'; (app/'Native').mkdir(parents=True,exist_ok=True)
base=source_repo/'iosapp/Nodyssey/Native'; hashes={}
files=[]
for module in ['Content','Editing','Rendering','Sharing','Foundation']:
    files += [p for p in (base/module).glob('*.swift') if p.name != 'NativeClient.swift']
files += [base/'Media'/name for name in ['MediaDomain.swift','MediaSupport.swift','NativeStickerGroup.swift']]
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
shipping_paths=subprocess.check_output(['git','ls-tree','-r','--name-only',source_commit,'iosapp/Nodyssey/Native','iosapp/NativeCore'],text=True).splitlines()
shipping_hashes={p:hashlib.sha256((source_repo/p).read_bytes()).hexdigest() for p in shipping_paths}
expected_path=repo/'iosapp/Glass72Diagnostic/expectedSources.json'
expected=json.loads(expected_path.read_text())
if os.environ.get('DIAG_SOURCE') == 'candidate':
    assert shipping_hashes == expected['files'], 'Candidate shipping bytes differ from frozen 128-file snapshot'
for src in (source_repo/'iosapp/NativeCore/Sources').rglob('*.swift'): hashes[str(src.relative_to(source_repo))]=hashlib.sha256(src.read_bytes()).hexdigest()
for src in base.rglob('*.strings'):
    target=app/'Native'/src.parent.name/src.name; target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,target)
for src in base.rglob('*.xcstrings'):
    shutil.copy2(src,app/'Native'/src.name)
project=stage/'iosapp/Nodyssey.xcodeproj/project.pbxproj'; s=project.read_text().replace('A1000000000000000000002 /* AppIcon.icon in Resources */,','').replace('A1000000000000000000070 /* Build Kotlin framework */,','')
s=re.sub(r'\s*FRAMEWORK_SEARCH_PATHS = \([^;]+;', '',s); s=re.sub(r'\s*OTHER_LDFLAGS = \([^;]+;', '',s)
s=re.sub(r'\s*"EXCLUDED_ARCHS\[sdk=iphonesimulator\*\]" = x86_64;', '',s); project.write_text(s)
(app/'Info.plist').write_text('''<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string><key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string><key>CFBundleName</key><string>$(PRODUCT_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>71</string><key>CFBundleShortVersionString</key><string>1.0</string><key>UILaunchScreen</key><dict/></dict></plist>''')
shutil.copy2(repo/'iosapp/Glass72Diagnostic/Fixture.swift',app/'App.swift')
shutil.copy2(repo/'iosapp/Glass72Diagnostic/Geometry.swift',app/'Native/Geometry.swift')
test=stage/'iosapp/NativeNavigationUITests'; test.mkdir(exist_ok=True); shutil.copy2(repo/'iosapp/Glass72Diagnostic/Tests.swift',test/'NativeNavigationUITests.swift')
(stage/'sources.json').write_text(json.dumps({'productionCommit':source_commit,'sourceCommit': subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(), 'baseline':'baede138d8bcef206ecc2d392c2038fd445633ec','files':hashes,'shippingSources':shipping_hashes,'expectedSnapshotManifestSHA256':hashlib.sha256(expected_path.read_bytes()).hexdigest(),'boundaries':['Synthetic Kotlin/network NativeTransport','No remote images or external browser; fixture text only','Real Root/Feed/Search/Notifications/Profile/PostDetail/Reply and observers']},indent=2))
print(stage)
