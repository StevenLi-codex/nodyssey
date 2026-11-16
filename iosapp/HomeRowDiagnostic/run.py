from pathlib import Path
import os,json,subprocess,shutil,sys
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
source=root/'HomeRow/iosapp/Nodyssey/Native/NativeAccountScreens.swift'
green=source.read_text()
assert '.background(AccountSurface(canvas: true).ignoresSafeArea(.container))' in green
results={}
for phase in ['green']:
    source.write_text(green.replace('.background(AccountSurface(canvas: true).ignoresSafeArea(.container))','.background(AccountSurface(canvas: true))') if phase=='red' else green)
    result=evidence/(phase+'.xcresult')
    command=['xcodebuild','test','-project',str(root/'HomeRow/iosapp/Nodyssey.xcodeproj'),'-scheme','Nodyssey','-configuration','Debug','-destination','platform=iOS Simulator,id='+phone['udid'],'-derivedDataPath',str(root/'ProfileDerived'),'-resultBundlePath',str(result),'-only-testing:NativeNavigationUITests','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','ASSETCATALOG_COMPILER_APPICON_NAME=']
    if phase=='red': command += ['-skip-testing:NativeNavigationUITests/NativeNavigationUITests/testSameHostProductionPresetMenuAndSheet']
    (evidence/(phase+'-command.json')).write_text(json.dumps(command))
    with (evidence/(phase+'-xcodebuild.log')).open('w') as log: code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
    print(phase,'xcodebuild exit',code)
    for line in (evidence/(phase+'-xcodebuild.log')).read_text().splitlines():
        if any(x in line for x in ['error:','SEAM ','BACKGROUND ','Test Case ','Executed ','TEST FAILED','TEST SUCCEEDED']): print(line)
    if result.exists():
        for name in ['summary','tests']:
            with (evidence/(phase+'-'+name+'.json')).open('w') as out: subprocess.run(['xcrun','xcresulttool','get','test-results',name,'--path',str(result)],stdout=out,check=False)
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(evidence/(phase+'-attachments'))],check=False)
        try: results[phase]=json.loads((evidence/(phase+'-summary.json')).read_text())
        except Exception: pass
source.write_text(green)
(evidence/'results.json').write_text(json.dumps(results,indent=2))
assert results.get('green',{}).get('totalTestCount')==3,results
assert results['green']['failedTests']==0 and results['green']['passedTests']==3,results
