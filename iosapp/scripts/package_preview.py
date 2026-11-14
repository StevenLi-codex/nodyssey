"""Package only a real xcodebuild archive, validating the independent app identity."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

archive, output = map(Path, sys.argv[1:])
app = archive / 'Products/Applications/Nodyssey.app'
with (app / 'Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['CFBundleIdentifier'] == 'io.github.nodyssey.preview', info['CFBundleIdentifier']
assert info['CFBundleDisplayName'] == 'Nodyssey Preview'
assert 'iPhoneOS' in info['CFBundleSupportedPlatforms']
executable = app / info['CFBundleExecutable']
assert executable.is_file() and executable.stat().st_size > 0
subprocess.run(['xcrun', 'lipo', '-verify_arch', 'arm64', str(executable)], check=True)
assert not (app / 'embedded.mobileprovision').exists(), 'Unexpected provisioned application'
assert not list(app.rglob('*.entitlements')), 'Unexpected shared/keychain entitlements'
payload = output / 'Payload'
payload.mkdir(exist_ok=True)
shutil.copytree(app, payload / app.name, dirs_exist_ok=True)
ipa = output / 'nodyssey-preview-unsigned.ipa'
subprocess.run(['zip', '-qry', str(ipa), 'Payload'], cwd=output, check=True)
manifest = {'bundle_id': info['CFBundleIdentifier'], 'display_name': info['CFBundleDisplayName'], 'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(), 'size_bytes': ipa.stat().st_size, 'head_sha': os.environ.get('GITHUB_SHA'), 'unsigned': True, 'guest_only': True, 'acceptance': 'Device archive only; not full acceptance. Signing and physical-device installation remain required.'}
(output / 'preview-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
