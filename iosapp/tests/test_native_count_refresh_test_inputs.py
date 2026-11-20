import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DISPATCH = ROOT / "iosapp/tests/delivery/NativeCountRefreshDispatchTest.kt"
IOS_TEST = ROOT / "iosapp/src/iosTest/kotlin/io/github/nodyssey/ios/native/NativeCountRefreshDispatchTest.kt"
RUNNER = ROOT / "iosapp/tests/native_private_delivery_test.py"


class NativeCountRefreshTestInputsTest(unittest.TestCase):
    def test_jvm_dispatch_fixture_is_not_in_apple_ios_test_source_set(self):
        self.assertTrue(DISPATCH.is_file(), "dispatch fixture must live in the JVM runner source area")
        self.assertFalse(IOS_TEST.exists(), "JVM-only JUnit/Proxy fixture must not be compiled as iosTest")
        source = DISPATCH.read_text()
        self.assertIn("org.junit.Test", source)
        self.assertIn("java.lang.reflect.Proxy", source)

    def test_checked_in_jvm_runner_has_explicit_dispatch_mode_and_real_sources(self):
        source = RUNNER.read_text()
        self.assertRegex(source, r"--count-refresh-dispatch")
        for required in (
            "NativeCountRefreshDispatchTest.kt",
            "NativeCountRefreshOwnerTest.kt",
            "NotificationRepository.kt",
            "MessageRepository.kt",
            "IosGlobalServices.kt",
            "AppContainer.kt",
            "NativeBridge.kt",
            "NativeContent.kt",
            "NativeCountRefreshOwner.kt",
        ):
            self.assertIn(required, source)


if __name__ == "__main__":
    unittest.main()
