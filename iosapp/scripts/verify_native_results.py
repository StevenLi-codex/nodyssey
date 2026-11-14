#!/usr/bin/env python3
"""Reject skipped/missing native suites even when a Gradle task reports success."""
import argparse
from collections import Counter
import json
from pathlib import Path
import xml.etree.ElementTree as ET

REQUIRED_SUITES = (
    'NativeAccountTest', 'NativeBridgeTest', 'NativeContentMappingTest',
    'NativeContentTest', 'NativePlatformTest', 'NativeSettingsMappingTest',
    'NativeSettingsPersistenceTest', 'NativeSupplementTest',
    'NativeReleaseNotesTest', 'NativeReleaseNotesAppleTest',
    'NativeImageHostSelectionTest', 'NativeRequestCompletionTest',
)

REQUIRED_CASES = {
    'NativeRequestCompletionTest': (
        'normalCompletionWaitsForSuspendingFinally',
        'cancellationWaitsForFinallyAndStructuredChildCleanup',
        'cancellationWaitsForStructuredChildAndFinallyCleanup',
        'eachRegistrationRunsExactlyOnce',
        'registrationAfterCompletionRunsExactlyOnce',
        'registrationAfterCancelledCompletionRunsExactlyOnce',
        'mainCallbacksSurviveRequestAndOwnerCancellation',
    ),
    'NativeImageHostSelectionTest': (
        'missingOrMalformedExpectedProviderNeverListsOrDeletes',
        'sameProviderDeletesExactImageWithBackendOnlyToken',
        'missingIdDoesNotDeleteAnotherImage',
        'queuedDeleteValidatesProviderAfterTakingSettingsLock',
        'selectionCannotInterleaveBetweenDeletionListingAndDelete',
        'cancellationDuringDeletionListingReleasesLockWithoutDeleting',
        'providerBoundListRejectsSwitchBeforeDispatch',
        'switchAfterLastFrontendCheckCannotDeleteCollidingIdOnAnotherProvider',
    ),
}


def verify_results(directory: Path, required=REQUIRED_SUITES):
    required = set(required)
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
            short_suite = suite.rsplit('.', 1)[-1]
            if short_suite in required & REQUIRED_CASES.keys() and int(element.attrib.get('skipped', '0')):
                raise ValueError(f'Skipped cases declared in {suite}')
        if element.tag == 'testcase':
            name = element.attrib.get('classname') or suite
            failed = element.find('failure') is not None or element.find('error') is not None
            if failed:
                raise ValueError(f'Native tests failed in {name}')
            # Archived Gradle Apple XML appends this exact target to method names.
            # Do not strip arbitrary brackets/suffixes and accept a different case.
            method = element.attrib.get('name', '').removesuffix('[iosSimulatorArm64]')
            rows.append((name.rsplit('.', 1)[-1], method, element.find('skipped') is not None))
        for child in element:
            walk(child, suite)

    for path in paths:
        walk(ET.parse(path).getroot())
    executed = {name for name, _, skipped in rows if not skipped}
    missing = sorted(set(required) - executed)
    if missing:
        raise ValueError('Required suites missing or entirely skipped: ' + ', '.join(missing))
    # --required replaces the default suite list; case gates follow selected suites.
    for suite in sorted(required & REQUIRED_CASES.keys()):
        cases = [(method, skipped) for name, method, skipped in rows if name == suite]
        passed = {method for method, skipped in cases if not skipped}
        missing_cases = sorted(set(REQUIRED_CASES[suite]) - passed)
        if missing_cases:
            raise ValueError(f'Required cases missing or skipped in {suite}: ' + ', '.join(missing_cases))
        duplicates = sorted(method for method, count in Counter(method for method, _ in cases).items() if count > 1)
        if duplicates:
            raise ValueError(f'Duplicate cases in {suite}: ' + ', '.join(duplicates))
        skipped_cases = sorted(method for method, skipped in cases if skipped)
        if skipped_cases:
            raise ValueError(f'Skipped cases in {suite}: ' + ', '.join(skipped_cases))
    skipped = sum(int(skipped) for _, _, skipped in rows)
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
