"""Launch-only smoke; not UI, forum-network or physical-device acceptance."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

out = Path(os.environ['RUNNER_TEMP'])
app = out / 'PreviewSimulator/Build/Products/Debug-iphonesimulator/Nodyssey.app'
with (app / 'Info.plist').open('rb') as source:
    assert plistlib.load(source)['CFBundleIdentifier'] == 'io.github.nodyssey.preview'
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
runtime, phone = next((runtime, d) for runtime, entries in devices.items() if '.iOS-' in runtime for d in entries if d['isAvailable'] and 'iPhone' in d['name'])
udid = subprocess.check_output(['xcrun', 'simctl', 'create', 'Nodyssey-Guest-Preview', phone['deviceTypeIdentifier'], runtime], text=True).strip()
try:
    subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', udid, str(app)], check=True)
    launch = subprocess.check_output(['xcrun', 'simctl', 'launch', udid, 'io.github.nodyssey.preview'], text=True).strip()
    time.sleep(8)
    subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(out / 'preview-launch.png')], check=True)
    # launchctl proves the app still has a live process, not just a successful spawn.
    processes = subprocess.check_output(['xcrun', 'simctl', 'spawn', udid, 'launchctl', 'list'], text=True)
    lines = [line for line in processes.splitlines() if 'io.github.nodyssey.preview' in line]
    assert any(line.split()[0].isdigit() for line in lines), lines
    report = {'head_sha': os.environ['GITHUB_SHA'], 'device': phone['name'], 'launch': launch, 'process': lines, 'scope': 'Build, install, launch and 8-second survival only; no full acceptance claim'}
    (out / 'preview-smoke.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
finally:
    subprocess.run(['xcrun', 'simctl', 'shutdown', udid], check=False)
    subprocess.run(['xcrun', 'simctl', 'delete', udid], check=False)
