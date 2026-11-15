#!/usr/bin/env python3
"""Execute the production Turnstile coordinator against navigation fixtures.

Linux uses explicit WebKit boundary stand-ins (not a WebKit integration test).
--apple runs the same coordinator in actual WKWebView on macOS, offline.
No production document, challenge, credentials, cookies or tokens are fetched.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--swiftc', default='swiftc')
parser.add_argument('--apple', action='store_true')
parser.add_argument('--source', type=Path, default=ROOT / 'iosapp/Nodyssey/Native/Platform/NativeTurnstile.swift')
parser.add_argument('--parse-only', action='store_true')
parser.add_argument('--compiler-flag', action='append', default=[])
args = parser.parse_args()
source = args.source.read_text()
# Keep every production coordinator method intact, including security checks.
coordinator = source[source.index('    @MainActor\n    final class Coordinator:'):source.rfind('\n}')]
fixture = ROOT / 'iosapp/tests/fixtures'
prefix = (fixture / ('TurnstileAppleBoundary.swift' if args.apple else 'TurnstileBoundary.swift')).read_text()
tests = (fixture / ('TurnstileAppleFixture.swift' if args.apple else 'TurnstileNavigationFixture.swift')).read_text()
with tempfile.TemporaryDirectory(prefix='native-turnstile-', dir=os.environ.get('TMPDIR')) as folder:
    path = Path(folder)
    main = path / 'main.swift'
    main.write_text(prefix + '\nstruct NativeTurnstile {\n'
                    + 'var resetSignal: Int = 0\nlet onToken: (String) -> Void\nlet onExpired: () -> Void\nlet onUnavailable: () -> Void\n'
                    + coordinator + '\n}\n' + tests)
    exe = path / 'tests'
    if args.parse_only:
        subprocess.run([args.swiftc, '-frontend', '-parse', str(main)], check=True)
    else:
        subprocess.run([args.swiftc, '-swift-version', '5'] + args.compiler_flag + [str(main), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
