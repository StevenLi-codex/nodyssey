from pathlib import Path
import os,json,subprocess,shutil,sys,platform
root=Path(os.environ['RUNNER_TEMP']); evidence=root/'glass71-evidence'; evidence.mkdir(exist_ok=True)
def output(cmd): return subprocess.check_output(cmd,text=True)
(evidence/'toolchain.txt').write_text(output(['xcodebuild','-version'])+'\n'+output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'])+'\n'+platform.machine())
(evidence/'runtimes.json').write_text(output(['xcrun','simctl','list','runtimes','-j']))
devices=json.loads(output(['xcrun','simctl','list','devices','available','-j']))['devices']
phones=[(r,d) for r,ds in devices.items() if '.iOS-26' in r for d in ds if 'iPhone' in d['name'] and d['isAvailable']]
assert phones,'No installed iOS26 iPhone runtime; do not download silently'
runtime,phone=phones[0]
(evidence/'device.json').write_text(json.dumps({'runtime':runtime,'device':phone},indent=2))
(evidence/'head.txt').write_text(output(['git','rev-parse','HEAD']))
shutil.copy2(root/'Glass71/sources.json',evidence/'sources.json')
base=['xcodebuild','-project',str(root/'Glass71/iosapp/Nodyssey.xcodeproj'),'-scheme','Nodyssey','-configuration','Debug','-destination','platform=iOS Simulator,id='+phone['udid'],'-derivedDataPath',str(root/'Glass71Derived'),'-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','ASSETCATALOG_COMPILER_APPICON_NAME=','EXCLUDED_ARCHS=','IPHONEOS_DEPLOYMENT_TARGET=16.0']
def run(command,path,timeout):
    (path.parent/(path.stem+'-command.json')).write_text(json.dumps(command))
    with path.open('w') as log:
        try: code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=timeout).returncode
        except subprocess.TimeoutExpired: code=124
    print(path.name,'exit',code,flush=True)
    for line in path.read_text().splitlines():
        if any(x in line for x in ['error:','Test Case ','Executed ','TEST FAILED','TEST SUCCEEDED','GLASS71_SEAM','GLASS71_STRIP']): print(line,flush=True)
    return code
# Compile first: simultaneous Intel migration starved the compiler in an earlier run.
build=run(base+['build-for-testing'],evidence/'build.log',600)
assert build==0,'Compile/link gate failed; no UI acceptance claimed'
subprocess.run(['xcrun','simctl','boot',phone['udid']],check=False,timeout=90)
subprocess.run(['xcrun','simctl','bootstatus',phone['udid'],'-b'],check=True,timeout=600)
results={}
tests=['testLightCanvasAndNavigation','testDarkCanvasAndNavigation','testCustomCanvasAndNavigation','testCustomDarkCanvasAndNavigation'] # One union-only four-theme run; no baseline/smoke repeat.
for test in tests:
    dest=evidence/test; dest.mkdir(exist_ok=True)
    result=dest/'result.xcresult'
    code=run(base+['test-without-building','-resultBundlePath',str(result),'-only-testing:NativeNavigationUITests/NativeNavigationUITests/'+test,'-test-timeouts-enabled','YES','-default-test-execution-time-allowance','360','-maximum-test-execution-time-allowance','360'],dest/'xcodebuild.log',600)
    if result.exists():
        for name in ['summary','tests']:
            with (dest/(name+'.json')).open('w') as out: subprocess.run(['xcrun','xcresulttool','get','test-results',name,'--path',str(result)],stdout=out,check=False)
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(dest/'attachments')],check=False)
        try: results[test]=json.loads((dest/'summary.json').read_text())
        except Exception: results[test]={'exit':code,'incomplete':True}
    if 'Smoke' in test and code!=0: break
(evidence/'results.json').write_text(json.dumps(results,indent=2))
assert set(results)==set(tests),results
assert all(r.get('totalTestCount')==1 and r.get('passedTests')==1 and r.get('failedTests')==0 for r in results.values()),results
