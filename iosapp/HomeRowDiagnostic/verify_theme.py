"""Read-only assertions over original real-iOS probe data, not synthetic UI data."""
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
records=[json.loads(line) for line in (root/'theme70-uikit.jsonl').read_text().splitlines()]
palette={'twins':[143,111,0],'graphite':[53,96,110],'reimu':[188,48,56],'miku':[0,128,120]}
scopes=[]; checkpoints=[]; failures=[]; identities={}
for record in records:
    if record['delayMillis']!=1000:continue
    scope=record['scope']
    if scope not in scopes:scopes.append(scope)
    if len(scopes)>1 and scope==scopes[0]:continue # Covered push host is dimmed by UIKit, not stale tint.
    location='push' if scope==scopes[0] else 'sheet'
    preset=record['settings']['presetId'].split('"')[1]
    expected=palette[preset]
    assert record['settings']['themeMode']=='string("LIGHT")'
    assert record['settings']['colorSource']=='string("PRESET")'
    buttons=[n for n in record['nodes'] if 'menu' in n and n['tintAdjustmentMode']!=2 and n.get('configurationTitle','').startswith(('settings_preset_','settings_theme_','settings_color_source_'))]
    assert len(buttons)==3, (location,preset,len(buttons))
    samples=[]
    for button in buttons:
        role='preset' if button['configurationTitle'].startswith('settings_preset_') else 'theme' if button['configurationTitle'].startswith('settings_theme_') else 'source'
        key=(location,role)
        previous=identities.setdefault(key,button['identity'])
        if previous!=button['identity']:failures.append(f'{location}/{role}: button remounted')
        labels=[n for n in record['nodes'] if n['path'].startswith(button['path']+'/') and n['class']=='UILabel' and n.get('text')==button['configurationTitle']]
        assert len(labels)==1,(location,preset,role,labels)
        label=labels[0]
        previous=identities.setdefault((location,role+'-label'),label['identity'])
        if previous!=label['identity']:failures.append(f'{location}/{role}: label remounted')
        colors={'tint':button['tint'],'titleColor':button['titleColor'],'labelTextColor':label['textColor']}
        for channel,rgba in colors.items():
            actual=[round(c*255) for c in rgba[:3]]
            if max(abs(a-b) for a,b in zip(actual,expected))>1:failures.append(f'{location}/{preset}/{role}/{channel}: {actual} != {expected}')
        samples.append({'role':role,'button':button['identity'],'label':label['identity'],'title':button['configurationTitle'],'colors':colors})
    checkpoints.append({'location':location,'preset':preset,'controls':samples})
sequences={location:[c['preset'] for c in checkpoints if c['location']==location] for location in ['push','sheet']}
assert sequences=={'push':['twins','graphite','reimu','miku','graphite'],'sheet':['graphite','miku','graphite']},sequences
report={'originalSnapshots':len(records),'checkpoints':checkpoints,'sequences':sequences,'failures':failures,'passed':not failures}
(root/'derived-theme-verification.json').write_text(json.dumps(report,indent=2))
print(json.dumps({'originalSnapshots':len(records),'checkpoints':len(checkpoints),'sequences':sequences,'failedColorOrIdentityChecks':len(failures),'firstFailures':failures[:9]},indent=2))
assert not failures, f'{len(failures)} stale tint or identity failures; see derived-theme-verification.json'
