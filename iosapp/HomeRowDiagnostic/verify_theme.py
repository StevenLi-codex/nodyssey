"""Assert actual closed-menu pixels, native owner identity and selected menu actions.
Disposable iOS diagnostics only: replacing UILabel with SwiftUI never skips color checks.
"""
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
records=[json.loads(line) for line in (root/'theme70-uikit.jsonl').read_text().splitlines()]
log=(root/'green-xcodebuild.log').read_text()
def lines(marker):
    return [json.loads(line.split(marker,1)[1]) for line in log.splitlines() if marker in line]
samples=lines('THEME70_CONTROL '); menus=lines('THEME70_MENU ')
failures=[]; identities={}; evidence=[]
expected_suffixes=['push-initial','push-graphite','push-reimu','push-miku','mode-dark','mode-light','mode-system','push-graphite-return','push-after-detail','sheet-initial','sheet-miku','sheet-graphite','push-after-sheet']
prefix='system-dark-' if root.name=='dark' else 'theme-'
expected_names=[prefix+s for s in expected_suffixes]
assert list(dict.fromkeys(s['name'] for s in samples))==expected_names, [s['name'] for s in samples]
assert len(samples)==len(expected_names)*3, len(samples)
def actions(menu):
    if 'state' in menu: return [menu]
    return [a for child in menu.get('children',[]) for a in actions(child)]
def frame_matches(a,b):
    return max(abs(x-y) for x,y in zip(a,b))<3
for sample in samples:
    if max(abs(a-b) for a,b in zip(sample['actual'],sample['expected']))>2 or sample['count']<=20:
        failures.append(f"{sample['name']}/{sample['role']}: stale or missing actual glyphs {sample['actual']} != {sample['expected']}")
    relevant=[r for r in records if abs(r['timestamp']-sample['timestamp'])<3 and r['settings']['presetId']=='string("'+sample['preset']+'")' and r['settings']['themeMode']=='string("'+sample['mode']+'")']
    found=[]
    for r in sorted(relevant,key=lambda r:abs(r['timestamp']-sample['timestamp'])):
        for n in r['nodes']:
            if n.get('hidden') or n.get('alpha',1)<0.9 or n.get('tintAdjustmentMode')==2 or not n.get('enabled',True):continue
            if ('menu' in n or n.get('contextMenuInteractions')) and frame_matches(n['frame'],sample['frame']):
                found.append((r,n))
        if found: break
    if len(found)!=1:
        failures.append(f"{sample['name']}/{sample['role']}: expected exactly one live menu owner at {sample['frame']}, got {len(found)}")
        continue
    record,node=found[0]
    location='sheet' if '-sheet-' in sample['name'] else 'push'
    key=(location,sample['role'])
    identity=(node['identity'],tuple(node.get('contextMenuInteractions',[])))
    prior=identities.setdefault(key,identity)
    if prior!=identity:failures.append(f'{key}: owner remounted {prior} -> {identity}')
    evidence.append(dict(sample,owner=node['identity'],ownerClass=node['class'],interactions=node.get('contextMenuInteractions'),snapshotTime=record['timestamp'],scope=record['scope']))
checkmarks=[]; busy_checks=[]
for check in menus:
    nearby=[r for r in records if abs(r['timestamp']-check['timestamp'])<1.5]
    matches=[]
    for r in nearby:
        for n in r['nodes']:
            aa=actions(n.get('menu',{}))
            if any(a.get('title')==check['selected'] and a.get('state')==1 for a in aa):matches.append((r,n,aa))
    if not matches: failures.append(f"{check['name']}: selected UIAction/checkmark missing for {check['selected']}")
    else:checkmarks.append(dict(check,owner=matches[0][1]['identity']))
    location='sheet' if '-sheet-' in check['name'] else 'push'
    owners={identities[(location,role)][0] for role in ['theme','source','preset']}
    disabled=[]
    for r in records:
        if check['timestamp']<r['timestamp']<check['timestamp']+8:
            nodes=[n for n in r['nodes'] if n['identity'] in owners and n.get('enabled') is False]
            if len(nodes)==3: disabled.append(r['timestamp'])
    if not disabled:failures.append(f"{check['name']}: no atomic all-disabled snapshot during save")
    else:busy_checks.append({'name':check['name'],'timestamps':disabled})
assert len(menus)==9,len(menus)
report={'snapshots':len(records),'samples':evidence,'identities':{str(k):v for k,v in identities.items()},'checkmarks':checkmarks,'busyChecks':busy_checks,'failures':failures,'passed':not failures}
(root/'derived-theme-verification.json').write_text(json.dumps(report,indent=2))
print(json.dumps({'snapshots':len(records),'checkpoints':len(expected_names),'samples':len(samples),'identityMatches':len(evidence),'checkmarks':len(checkmarks),'failures':failures},indent=2))
assert not failures, failures
