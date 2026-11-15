#!/usr/bin/env python3
"""Exercise the actual browser controller offline on macOS.

Real WKWebView, test-only UIKit/Kotlin signatures. Does not validate UIKit layout,
Kotlin/Native linking, real cookies, successful login or Cloudflare.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--swiftc', default='swiftc')
parser.add_argument('--source', type=Path, default=root / 'iosapp/Nodyssey/Native/Platform/NativeBrowser.swift')
args = parser.parse_args()
source = args.source.read_text()
controller = source[source.index('@MainActor\nprivate final class AuthenticationController:'):source.index('\n/// Ordinary external content;')]
fixtures = root / 'iosapp/tests/fixtures'
with tempfile.TemporaryDirectory(prefix='browser-controller-', dir=os.environ['TMPDIR']) as folder:
    folder = Path(folder)
    main = folder / 'main.swift'
    main.write_text((fixtures / 'BrowserControllerBoundary.swift').read_text() + '\n' + controller + '\n' +
                    (fixtures / 'BrowserControllerLifecycleFixture.swift').read_text())
    executable = folder / 'tests'
    subprocess.run([args.swiftc, '-swift-version', '5', str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=15)
