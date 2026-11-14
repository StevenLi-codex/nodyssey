import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name('sync_native_strings.py')


class NativeStringsTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE_PATH.exists(), 'native localization converter not implemented')
        spec = importlib.util.spec_from_file_location('sync_native_strings', MODULE_PATH)
        assert spec is not None and spec.loader is not None
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_positional_string_and_literal_percent(self):
        self.assertEqual(self.module.apple_format('%1$s · %2$d · %%s'), '%1$@ · %2$d · %%s')

    def test_escaped_xml_text_and_fallback_preserve_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'strings.xml'
            path.write_text('<resources><string name="a">第一行\\n&quot;引号&quot; &amp; 内容</string><string name="b">%1$s</string></resources>')
            parsed = self.module.read_strings(path)
        self.assertEqual(parsed['a'], '第一行\n"引号" & 内容')
        self.assertEqual(parsed['b'], '%1$@')
        self.assertEqual(self.module.with_fallback({'a': '原文', 'b': '原文乙'}, {'a': 'translation'}), {'a': 'translation', 'b': '原文乙'})

    def test_strings_file_escaping_is_lossless(self):
        self.assertEqual(self.module.quote_strings('a"\\\n\t'), '"a\\"\\\\\\n\\t"')

    def test_percentage_in_prose_is_not_a_printf_flag(self):
        self.assertEqual(self.module.apple_format('100%, then continue at 50% speed'), '100%, then continue at 50% speed')

    def test_unknown_placeholders_are_rejected(self):
        with self.assertRaises(ValueError):
            self.module.apple_format('%1$q')


if __name__ == '__main__':
    unittest.main()
