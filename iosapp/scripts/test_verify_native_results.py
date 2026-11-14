import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('verify_native_results', Path(__file__).with_name('verify_native_results.py'))
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


# Exact methods in the concrete iosTest contract; do not derive fixtures from
# the verifier's allowlist (that would hide accidentally omitted requirements).
IMAGE_HOST_CASES = (
    'missingOrMalformedExpectedProviderNeverListsOrDeletes',
    'sameProviderDeletesExactImageWithBackendOnlyToken',
    'missingIdDoesNotDeleteAnotherImage',
    'queuedDeleteValidatesProviderAfterTakingSettingsLock',
    'selectionCannotInterleaveBetweenDeletionListingAndDelete',
    'cancellationDuringDeletionListingReleasesLockWithoutDeleting',
    'providerBoundListRejectsSwitchBeforeDispatch',
    'switchAfterLastFrontendCheckCannotDeleteCollidingIdOnAnotherProvider',
)

REQUEST_COMPLETION_CASES = (
    'normalCompletionWaitsForSuspendingFinally',
    'cancellationWaitsForFinallyAndStructuredChildCleanup',
    'cancellationWaitsForStructuredChildAndFinallyCleanup',
    'eachRegistrationRunsExactlyOnce',
    'registrationAfterCompletionRunsExactlyOnce',
    'registrationAfterCancelledCompletionRunsExactlyOnce',
    'mainCallbacksSurviveRequestAndOwnerCancellation',
)

PREEXISTING_SUITES = (
    'NativeAccountTest', 'NativeBridgeTest', 'NativeContentMappingTest',
    'NativeContentTest', 'NativePlatformTest', 'NativeSettingsMappingTest',
    'NativeSettingsPersistenceTest', 'NativeSupplementTest',
    'NativeReleaseNotesTest', 'NativeReleaseNotesAppleTest',
)


def preexisting_suites_xml():
    return ''.join(f'<testsuite name="{suite}"><testcase name="oldCase"/></testsuite>'
                   for suite in PREEXISTING_SUITES)


def image_host_xml(cases=IMAGE_HOST_CASES, skipped=(), suffix='[iosSimulatorArm64]'):
    # Shape observed in archived Apple Gradle XML, not a claim of native execution.
    suite = 'iosSimulatorArm64Test.io.github.nodyssey.ios.native.NativeImageHostSelectionTest'
    rows = ''.join(
        f'<testcase classname="{suite}" name="{name}{suffix}">'
        + ('<skipped/>' if name in skipped else '') + '</testcase>'
        for name in cases
    )
    return f'<testsuite name="{suite}" tests="{len(cases)}">{rows}</testsuite>'


def request_completion_xml(cases=REQUEST_COMPLETION_CASES, skipped=(), suffix='[iosSimulatorArm64]'):
    # Synthetic verifier input, never evidence of executing the Apple suite.
    suite = 'iosSimulatorArm64Test.io.github.nodyssey.ios.native.NativeRequestCompletionTest'
    rows = ''.join(
        f'<testcase classname="{suite}" name="{name}{suffix}">'
        + ('<skipped/>' if name in skipped else '') + '</testcase>'
        for name in cases
    )
    return f'<testsuite name="{suite}" tests="{len(cases)}">{rows}</testsuite>'


class NativeResultsTest(unittest.TestCase):
    def test_default_gate_requires_request_completion_suite(self):
        with self.assertRaisesRegex(ValueError, 'NativeRequestCompletionTest'):
            self.check_xml('<testsuites>' + preexisting_suites_xml() + image_host_xml() + '</testsuites>', None)

    def test_request_completion_missing_each_exact_case_fails_default_gate(self):
        for missing in REQUEST_COMPLETION_CASES:
            cases = tuple(name for name in REQUEST_COMPLETION_CASES if name != missing)
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, missing):
                self.check_xml('<testsuites>' + preexisting_suites_xml() + image_host_xml()
                               + request_completion_xml(cases) + '</testsuites>', None)

    def test_request_completion_each_skipped_case_fails(self):
        for skipped in REQUEST_COMPLETION_CASES:
            with self.subTest(skipped=skipped), self.assertRaisesRegex(ValueError, skipped):
                self.check_xml(request_completion_xml(skipped=(skipped,)), ('NativeRequestCompletionTest',))

    def test_request_completion_duplicate_cannot_replace_missing_case(self):
        cases = REQUEST_COMPLETION_CASES[:-1] + REQUEST_COMPLETION_CASES[:1]
        with self.assertRaisesRegex(ValueError, REQUEST_COMPLETION_CASES[-1]):
            self.check_xml(request_completion_xml(cases), ('NativeRequestCompletionTest',))

    def test_request_completion_duplicates_across_files_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'TEST-native.xml').write_text(request_completion_xml())
            Path(directory, 'TEST-duplicate.xml').write_text(request_completion_xml(REQUEST_COMPLETION_CASES[:1], suffix=''))
            with self.assertRaisesRegex(ValueError, 'Duplicate.*' + REQUEST_COMPLETION_CASES[0]):
                module.verify_results(Path(directory), ('NativeRequestCompletionTest',))

    def test_request_completion_declared_skip_fails(self):
        xml = request_completion_xml().replace('tests="7"', 'tests="7" skipped="1"')
        with self.assertRaisesRegex(ValueError, 'Skipped.*NativeRequestCompletionTest'):
            self.check_xml(xml, ('NativeRequestCompletionTest',))

    def test_request_completion_extra_skipped_case_fails(self):
        xml = request_completion_xml(REQUEST_COMPLETION_CASES + ('extraCase',), skipped=('extraCase',))
        with self.assertRaisesRegex(ValueError, 'Skipped.*extraCase'):
            self.check_xml(xml, ('NativeRequestCompletionTest',))

    def test_request_completion_unknown_suffix_fails(self):
        with self.assertRaisesRegex(ValueError, REQUEST_COMPLETION_CASES[0]):
            self.check_xml(request_completion_xml(suffix='[not-an-apple-target]'), ('NativeRequestCompletionTest',))

    def test_request_completion_plain_or_apple_methods_pass(self):
        for suffix in ('', '[iosSimulatorArm64]'):
            with self.subTest(suffix=suffix):
                result = self.check_xml(request_completion_xml(suffix=suffix), ('NativeRequestCompletionTest',))
                self.assertEqual((result['passed'], result['skipped']), (7, 0))

    def test_request_completion_failure_or_error_fails(self):
        for tag in ('failure', 'error'):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, 'failed'):
                xml = request_completion_xml().replace('</testcase>', f'<{tag}/></testcase>', 1)
                self.check_xml(xml, ('NativeRequestCompletionTest',))

    def test_default_gate_rejects_old_suites_without_image_host_suite(self):
        with self.assertRaisesRegex(ValueError, 'NativeImageHostSelectionTest'):
            self.check_xml('<testsuites>' + preexisting_suites_xml() + request_completion_xml() + '</testsuites>', None)

    def test_default_gate_accepts_old_suites_plus_image_host_and_completion_cases(self):
        result = self.check_xml('<testsuites>' + preexisting_suites_xml() + image_host_xml()
                                + request_completion_xml() + '</testsuites>', None)
        self.assertEqual(result['passed'], 25)
        self.assertEqual(result['required_suites'], sorted(PREEXISTING_SUITES + (
            'NativeImageHostSelectionTest', 'NativeRequestCompletionTest')))

    def test_image_host_declared_skip_without_child_is_not_ignored(self):
        xml = image_host_xml().replace('tests="8"', 'tests="8" skipped="1"')
        with self.assertRaisesRegex(ValueError, 'Skipped.*NativeImageHostSelectionTest'):
            self.check_xml(xml, ('NativeImageHostSelectionTest',))

    def test_image_host_failure_or_error_blocks_complete_coverage(self):
        for tag in ('failure', 'error'):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, 'failed'):
                xml = image_host_xml().replace('</testcase>', f'<{tag}/></testcase>', 1)
                self.check_xml(xml, ('NativeImageHostSelectionTest',))

    def test_image_host_extra_skipped_case_is_not_zero_skips(self):
        xml = image_host_xml(IMAGE_HOST_CASES + ('extraCase',), skipped=('extraCase',))
        with self.assertRaisesRegex(ValueError, 'Skipped.*extraCase'):
            self.check_xml(xml, ('NativeImageHostSelectionTest',))

    def test_required_cli_override_remains_repeatable_and_replaces_defaults(self):
        xml = ('<testsuites><testsuite name="AccountTest"><testcase name="a"/></testsuite>'
               '<testsuite name="PlatformTest"><testcase name="b"/></testsuite>'
               + image_host_xml(IMAGE_HOST_CASES[:1]) + '</testsuites>')
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'TEST-native.xml').write_text(xml)
            command = [sys.executable, str(Path(__file__).with_name('verify_native_results.py')),
                       directory, '--required', 'AccountTest', '--required', 'PlatformTest']
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['required_suites'], ['AccountTest', 'PlatformTest'])
            result = subprocess.run(command + ['--required', 'NativeImageHostSelectionTest'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(IMAGE_HOST_CASES[-1], result.stderr)

    def test_image_host_missing_one_named_case_is_not_acceptance(self):
        for missing in IMAGE_HOST_CASES:
            cases = tuple(name for name in IMAGE_HOST_CASES if name != missing)
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, missing):
                self.check_xml(image_host_xml(cases), ('NativeImageHostSelectionTest',))

    def test_image_host_one_skipped_case_is_not_acceptance(self):
        for skipped in IMAGE_HOST_CASES:
            with self.subTest(skipped=skipped), self.assertRaisesRegex(ValueError, skipped):
                self.check_xml(image_host_xml(skipped=(skipped,)), ('NativeImageHostSelectionTest',))

    def test_image_host_duplicate_cannot_substitute_for_missing_case(self):
        cases = IMAGE_HOST_CASES[:-1] + (IMAGE_HOST_CASES[0],)
        with self.assertRaisesRegex(ValueError, IMAGE_HOST_CASES[-1]):
            self.check_xml(image_host_xml(cases), ('NativeImageHostSelectionTest',))

    def test_image_host_complete_eight_apple_cases_pass(self):
        result = self.check_xml(image_host_xml(), ('NativeImageHostSelectionTest',))
        self.assertEqual(result['tests'], 8)
        self.assertEqual(result['passed'], 8)
        self.assertEqual(result['skipped'], 0)

    def test_image_host_complete_eight_plain_method_names_pass(self):
        result = self.check_xml(image_host_xml(suffix=''), ('NativeImageHostSelectionTest',))
        self.assertEqual(result['passed'], 8)

    def test_image_host_unknown_suffix_cannot_impersonate_exact_case(self):
        with self.assertRaisesRegex(ValueError, IMAGE_HOST_CASES[0]):
            self.check_xml(image_host_xml(suffix='[not-an-apple-target]'), ('NativeImageHostSelectionTest',))

    def test_image_host_duplicate_even_with_complete_coverage_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate.*' + IMAGE_HOST_CASES[0]):
            self.check_xml(image_host_xml(IMAGE_HOST_CASES + (IMAGE_HOST_CASES[0],)), ('NativeImageHostSelectionTest',))

    def test_image_host_duplicate_across_xml_files_and_suffix_forms_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'TEST-native.xml').write_text(image_host_xml())
            Path(directory, 'TEST-duplicate.xml').write_text(image_host_xml(IMAGE_HOST_CASES[:1], suffix=''))
            with self.assertRaisesRegex(ValueError, 'Duplicate.*' + IMAGE_HOST_CASES[0]):
                module.verify_results(Path(directory), ('NativeImageHostSelectionTest',))

    def test_image_host_suite_name_fallback_preserves_case_gate(self):
        import xml.etree.ElementTree as ET
        root = ET.fromstring(image_host_xml())
        for case in root.findall('testcase'):
            del case.attrib['classname']
        result = self.check_xml(ET.tostring(root, encoding='unicode'), ('NativeImageHostSelectionTest',))
        self.assertEqual(result['passed'], 8)

    def check_xml(self, xml, required=('AccountTest', 'PlatformTest')):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'TEST-native.xml').write_text(xml)
            if required is None:
                return module.verify_results(Path(directory))
            return module.verify_results(Path(directory), required)

    def test_successful_task_with_missing_suite_is_not_acceptance(self):
        with self.assertRaisesRegex(ValueError, 'PlatformTest'):
            self.check_xml('<testsuite name="AccountTest" tests="1"><testcase name="a"/></testsuite>')

    def test_skipped_cases_do_not_satisfy_required_suite(self):
        with self.assertRaisesRegex(ValueError, 'PlatformTest'):
            self.check_xml('<testsuites><testsuite name="AccountTest"><testcase name="a"/></testsuite>'
                           '<testsuite name="PlatformTest"><testcase name="b"><skipped/></testcase></testsuite></testsuites>')

    def test_failure_in_additional_suite_also_blocks_acceptance(self):
        with self.assertRaisesRegex(ValueError, 'failed'):
            self.check_xml('<testsuite><testcase classname="AccountTest" name="a"/>'
                           '<testcase classname="PlatformTest" name="b"/>'
                           '<testcase classname="ExtraTest" name="c"><failure>bad</failure></testcase></testsuite>')

    def test_nested_suites_use_classname_and_count_once(self):
        result = self.check_xml('<testsuites><testsuite name="native" tests="3">'
                                '<testcase classname="pkg.AccountTest" name="a"/>'
                                '<testcase classname="pkg.PlatformTest" name="b"/>'
                                '<testcase classname="pkg.ExtraTest" name="c"><skipped/></testcase>'
                                '</testsuite></testsuites>')
        self.assertEqual(result['tests'], 3)
        self.assertEqual(result['passed'], 2)
        self.assertEqual(result['skipped'], 1)
        self.assertEqual(result['required_suites'], ['AccountTest', 'PlatformTest'])

    def test_no_xml_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'No JUnit'):
                module.verify_results(Path(directory), ['AccountTest'])

    def test_declared_total_must_match_enumerated_cases(self):
        with self.assertRaisesRegex(ValueError, 'count'):
            self.check_xml('<testsuite tests="3"><testcase classname="AccountTest" name="a"/>'
                           '<testcase classname="PlatformTest" name="b"/></testsuite>')

    def test_declared_failure_without_testcase_is_not_ignored(self):
        with self.assertRaisesRegex(ValueError, 'failed'):
            self.check_xml('<testsuite failures="1"><testcase classname="AccountTest" name="a"/>'
                           '<testcase classname="PlatformTest" name="b"/></testsuite>')


if __name__ == '__main__':
    unittest.main()
