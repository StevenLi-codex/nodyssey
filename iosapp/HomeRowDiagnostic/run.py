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
result=evidence/'profile.xcresult'
command=['xcodebuild','test','-project',str(root/'HomeRow/iosapp/Nodyssey.xcodeproj'),'-scheme','Nodyssey','-configuration','Debug','-destination','platform=iOS Simulator,id='+phone['udid'],'-derivedDataPath',str(root/'ProfileDerived'),'-resultBundlePath',str(result),'-only-testing:NativeNavigationUITests','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','ASSETCATALOG_COMPILER_APPICON_NAME=']
(evidence/'command.json').write_text(json.dumps(command))
with (evidence/'xcodebuild.log').open('w') as log: code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
print('xcodebuild exit',code)
for line in (evidence/'xcodebuild.log').read_text().splitlines():
    if any(x in line for x in ['error:','BACKGROUND ','Test Case ','Executed ','TEST FAILED','TEST SUCCEEDED']): print(line)
if result.exists():
    for name in ['summary','tests']:
        with (evidence/(name+'.json')).open('w') as out: subprocess.run(['xcrun','xcresulttool','get','test-results',name,'--path',str(result)],stdout=out,check=False)
    subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(evidence/'attachments')],check=False)
sys.exit(code)
