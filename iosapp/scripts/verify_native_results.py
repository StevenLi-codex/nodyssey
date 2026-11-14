#!/usr/bin/env python3
"""Reject skipped/missing native suites even when a Gradle task reports success."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

REQUIRED_SUITES = (
    'NativeAccountTest', 'NativeBridgeTest', 'NativeContentMappingTest',
    'NativeContentTest', 'NativePlatformTest', 'NativeSettingsMappingTest',
    'NativeSettingsPersistenceTest', 'NativeSupplementTest',
    'NativeReleaseNotesTest', 'NativeReleaseNotesAppleTest',
)


def verify_results(directory: Path, required=REQUIRED_SUITES):
    paths = sorted(directory.rglob('TEST-*.xml'))
    if not paths:
        raise ValueError(f'No JUnit XML in {directory}')
    rows = []

    def walk(element, suite=''):
        if element.tag in ('testsuite', 'testsuites') and 'tests' in element.attrib:
            actual = len(element.findall('.//testcase'))
            if int(element.attrib['tests']) != actual:
                raise ValueError(f'JUnit count mismatch: declared {element.attrib["tests"]}, actual {actual}')
        if element.tag == 'testsuite':
            suite = element.attrib.get('name', suite)
            if int(element.attrib.get('failures', '0')) or int(element.attrib.get('errors', '0')):
                raise ValueError(f'Native tests failed in {suite}')
        if element.tag == 'testcase':
            name = element.attrib.get('classname') or suite
            failed = element.find('failure') is not None or element.find('error') is not None
            if failed:
                raise ValueError(f'Native tests failed in {name}')
            rows.append((name.rsplit('.', 1)[-1], element.find('skipped') is not None))
        for child in element:
            walk(child, suite)

    for path in paths:
        walk(ET.parse(path).getroot())
    executed = {name for name, skipped in rows if not skipped}
    missing = sorted(set(required) - executed)
    if missing:
        raise ValueError('Required suites missing or entirely skipped: ' + ', '.join(missing))
    skipped = sum(int(skipped) for _, skipped in rows)
    return {'tests': len(rows), 'passed': len(rows) - skipped, 'skipped': skipped,
            'required_suites': sorted(set(required)), 'xml_files': len(paths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--required', action='append', help='Override required suite list; repeat as needed')
    args = parser.parse_args()
    result = verify_results(args.directory, args.required or REQUIRED_SUITES)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
