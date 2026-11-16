from pathlib import Path
import os,json,subprocess,shutil,sys,plistlib
root=Path(os.environ['RUNNER_TEMP']); evidence=root/'evidence'; evidence.mkdir(exist_ok=True)
def output(cmd): return subprocess.check_output(cmd,text=True)
(evidence/'toolchain.txt').write_text(output(['xcodebuild','-version']))
devices=json.loads(output(['xcrun','simctl','list','devices','available','-j']))['devices']
phone=next(d for r,ds in devices.items() if '.iOS-' in r for d in ds if 'iPhone' in d['name'] and d['isAvailable'])
(evidence/'device.json').write_text(json.dumps(phone,indent=2))
(evidence/'head.txt').write_text(output(['git','rev-parse','HEAD']))
shutil.copy2(root/'HomeRow/sources.json',evidence/'sources.json')
subprocess.run(['xcrun','simctl','boot',phone['udid']],check=False)
subprocess.run(['xcrun','simctl','bootstatus',phone['udid'],'-b'],check=True)
results={}; checks={}
for phase,test in [('light','testSameHostProductionPresetMenuAndSheet'),('dark','testSystemDarkProductionMenu')]:
    dest=evidence/phase; dest.mkdir(exist_ok=True)
    subprocess.run(['xcrun','simctl','ui',phone['udid'],'appearance',phase],check=True)
    (dest/'system-appearance.txt').write_text(output(['xcrun','simctl','ui',phone['udid'],'appearance']))
    result=dest/'green.xcresult'
    command=['xcodebuild','test','-project',str(root/'HomeRow/iosapp/Nodyssey.xcodeproj'),'-scheme','Nodyssey','-configuration','Debug','-destination','platform=iOS Simulator,id='+phone['udid'],'-derivedDataPath',str(root/'ProfileDerived'),'-resultBundlePath',str(result),'-only-testing:NativeNavigationUITests/NativeNavigationUITests/'+test,'-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','ASSETCATALOG_COMPILER_APPICON_NAME=']
    (dest/'command.json').write_text(json.dumps(command))
    with (dest/'green-xcodebuild.log').open('w') as log: code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
    print(phase,'xcodebuild exit',code)
    for line in (dest/'green-xcodebuild.log').read_text().splitlines():
        if any(x in line for x in ['error:','THEME70_CONTROL','THEME70_SWATCH','Test Case ','Executed ','TEST FAILED','TEST SUCCEEDED']): print(line)
    if result.exists():
        for name in ['summary','tests']:
            with (dest/('green-'+name+'.json')).open('w') as out: subprocess.run(['xcrun','xcresulttool','get','test-results',name,'--path',str(result)],stdout=out,check=False)
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(dest/'green-attachments')],check=False)
        try: results[phase]=json.loads((dest/'green-summary.json').read_text())
        except Exception: pass
    for candidate in (root/'ProfileDerived/Build/Products').glob('Debug-iphonesimulator/*.app'):
        bundle=plistlib.loads((candidate/'Info.plist').read_bytes())['CFBundleIdentifier']
        container=subprocess.run(['xcrun','simctl','get_app_container',phone['udid'],bundle,'data'],text=True,capture_output=True)
        if container.returncode==0:
            probe=Path(container.stdout.strip())/'Documents/theme70-uikit.jsonl'
            if probe.exists(): shutil.copy2(probe,dest/'theme70-uikit.jsonl'); probe.unlink()
    checks[phase]=subprocess.run([sys.executable,'iosapp/HomeRowDiagnostic/verify_theme.py',str(dest)]).returncode
(evidence/'results.json').write_text(json.dumps({'tests':results,'colorIdentityVerification':checks},indent=2))
assert all(results.get(p,{}).get('totalTestCount')==1 and results[p].get('passedTests')==1 and results[p].get('failedTests')==0 for p in ['light','dark']),results
assert checks=={'light':0,'dark':0},checks
