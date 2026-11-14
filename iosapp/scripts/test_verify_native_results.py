import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('verify_native_results', Path(__file__).with_name('verify_native_results.py'))
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class NativeResultsTest(unittest.TestCase):
    def check_xml(self, xml, required=('AccountTest', 'PlatformTest')):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'TEST-native.xml').write_text(xml)
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
