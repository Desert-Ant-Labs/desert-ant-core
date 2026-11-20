"""The gates must reject empty/skipped/crashed tests and stripped ICU payloads."""
import unittest
from pathlib import Path
from unittest.mock import patch
from artifacts import inspect, inspect_harness
from compatibility import apk_target_sdk, successful, runtime_metadata, valid_runtime

ALIGNED_HEADERS = '  LOAD 0x000000 0x000000 0x000000 0x001000 0x001000 R E 0x4000\n'


class InstrumentationGateTests(unittest.TestCase):
    def test_success_requires_executed_tests(self):
        self.assertEqual(3, successful('OK (3 tests)\nINSTRUMENTATION_CODE: -1'))
        self.assertEqual(1, successful('OK (1 test)'))
        for output in ('', 'OK (0 tests)', 'INSTRUMENTATION_CODE: -1', 'Tests run: 3, Failures: 1\nFAILURES!!!'):
            self.assertEqual(0, successful(output))

    def test_partial_success_cannot_hide_skips_or_crashes(self):
        for failure in ('INSTRUMENTATION_STATUS_CODE: -3', 'INSTRUMENTATION_STATUS_CODE: -4',
                        'INSTRUMENTATION_FAILED', 'Process crashed', 'shortMsg=Native crash', 'FAILURES!!!'):
            self.assertEqual(0, successful('OK (3 tests)\n' + failure))


class RuntimeMetadataTests(unittest.TestCase):
    def test_metadata_arrives_with_test_results_without_logcat(self):
        import json
        record = {'api': 24, 'abi': 'x86_64', 'icu': '56.1.0.0', 'unicode': '8.0.0.0'}
        output = ('INSTRUMENTATION_STATUS: dalUnicodeRuntime=' + json.dumps(record)
                  + '\nINSTRUMENTATION_STATUS_CODE: 2\nOK (6 tests)\nINSTRUMENTATION_CODE: -1\n')
        self.assertEqual(6, successful(output))
        self.assertEqual([record], runtime_metadata(output))
        self.assertTrue(valid_runtime(runtime_metadata(output), 24, 'x86_64'))
        self.assertEqual([record], runtime_metadata(output.replace('\n', '\r\n')))

    def test_missing_and_inconsistent_metadata_still_fail(self):
        record = {'api': 24, 'abi': 'x86_64', 'icu': '56.1', 'unicode': '8.0'}
        self.assertFalse(valid_runtime(runtime_metadata('OK (6 tests)'), 24, 'x86_64'))
        self.assertFalse(valid_runtime([record], 36, 'x86_64'))
        self.assertFalse(valid_runtime([record], 24, 'arm64-v8a'))
        for field in ('icu', 'unicode'):
            self.assertFalse(valid_runtime([dict(record, **{field: ''})], 24, 'x86_64'))

    def test_malformed_metadata_is_not_silently_accepted(self):
        import json
        with self.assertRaises(json.JSONDecodeError):
            runtime_metadata('INSTRUMENTATION_STATUS: dalUnicodeRuntime={invalid}\n')


class ArtifactGateTests(unittest.TestCase):
    @patch('artifacts.subprocess.check_output', side_effect=['0x01 (NEEDED) Shared library: [libc.so]', ALIGNED_HEADERS] * 2)
    def test_stripping_symbols_does_not_hide_data(self, _):
        self.assertIn('bundled ICU data', inspect(b'ELF\0icudt76l/nfkc.nrm\0', 'libEmoAndroid.so', 'readelf')['problems'])
        self.assertEqual([], inspect(b'ELF\0plain runtime', 'libEmoAndroid.so', 'readelf')['problems'])

    @patch('artifacts.subprocess.check_output', side_effect=['0x01 (NEEDED) Shared library: [libicui18n.so]', ALIGNED_HEADERS])
    def test_private_system_icu_dependency_fails(self, _):
        self.assertIn('ICU/Foundation dynamic dependency', inspect(b'ELF', 'libEmoAndroid.so', 'readelf')['problems'])

    def test_every_load_segment_must_support_16kb_pages(self):
        for headers in (ALIGNED_HEADERS.replace('0x4000', '0x1000'),
                        ALIGNED_HEADERS + '  LOAD 0x001000 0x002000 0x002000 0x001000 0x001000 RW 0x4000\n'):
            with self.subTest(headers=headers), patch('artifacts.subprocess.check_output', side_effect=['', headers]):
                self.assertIn('ELF LOAD segment is not 16 KB aligned', inspect(b'ELF', 'model.so', 'readelf')['problems'])
        with patch('artifacts.subprocess.check_output', side_effect=['', 'no headers']):
            self.assertIn('no ELF LOAD segments', inspect(b'ELF', 'model.so', 'readelf')['problems'])


class ApkTargetTests(unittest.TestCase):
    @patch('compatibility.sdk_root', return_value=Path('/sdk'))
    def test_target_is_read_from_apk_and_older_or_missing_targets_fail(self, _):
        with patch('compatibility.subprocess.check_output', return_value="package: name='test'\ntargetSdkVersion:'37'\n"):
            self.assertEqual(37, apk_target_sdk('test.apk'))
        for output in ("targetSdkVersion:'24'\n", "targetSdkVersion:'35'\n", '', "targetSdkVersion:'preview'\n"):
            with self.subTest(output=output), patch('compatibility.subprocess.check_output', return_value=output):
                with self.assertRaises(RuntimeError):
                    apk_target_sdk('test.apk')


class HarnessFloorTests(unittest.TestCase):
    def test_packaged_harness_rejects_api26_imports_on_api24(self):
        import tempfile
        import zipfile
        import artifacts
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'gradle').mkdir()
            (root / 'gradle/libs.versions.toml').write_text('minSdk = "24"\n')
            (root / 'ANDROID_NDK_VERSION').write_text('30\n')
            sdk = root / 'sdk'
            stubs = sdk / 'ndk/30/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/24'
            stubs.mkdir(parents=True)
            for name in ('libc.so', 'libm.so', 'libdl.so'):
                (stubs / name).touch()
            apk = root / 'test.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                for product in ('CoreAndroidTests', 'UnicodeAndroidTests'):
                    archive.writestr(f'lib/x86_64/lib{product}.so', b'fixture')
            for imported, rejected in (('strtod@LIBC', False), ('strtod_l@LIBC_O', True)):
                def readelf(command, **_):
                    if Path(command[-1]).parent == stubs:
                        return ' 1: 123 4 FUNC GLOBAL DEFAULT 1 strtod@@LIBC\n'
                    return f' 1: 000 0 FUNC GLOBAL DEFAULT UND {imported} (2)\n'
                with self.subTest(imported=imported), patch.object(artifacts, 'ROOT', root), \
                     patch('artifacts.sdk_root', return_value=sdk), \
                     patch('artifacts.readelf_tool', return_value='readelf'), \
                     patch('artifacts.subprocess.check_output', side_effect=readelf):
                    if rejected:
                        with self.assertRaisesRegex(RuntimeError, 'unavailable on API 24'):
                            inspect_harness(apk)
                    else:
                        self.assertEqual(2, len(inspect_harness(apk)['libraries']))


class InstallationDiagnosticsTests(unittest.TestCase):
    def test_install_failure_retains_logs_and_report_without_starting_tests(self):
        import hashlib
        import json
        import subprocess
        import tempfile
        import compatibility
        for error, expected in ((subprocess.TimeoutExpired(['install'], 180), 'install timed out after 180 seconds'),
                                (subprocess.CalledProcessError(1, ['install']), 'install exited with code 1')):
            with self.subTest(error=expected), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                prepared = base / 'prepared'
                prepared.mkdir()
                (prepared / 'test.apk').write_bytes(b'apk')
                (prepared / 'build.json').write_text(json.dumps({
                    'apkSha256': hashlib.sha256(b'apk').hexdigest(), 'targetSdk': 37, 'libraries': ['Model']}))
                with patch.object(compatibility, 'BASE', base), \
                     patch('compatibility.shutil.which', return_value='adb'), \
                     patch('compatibility.subprocess.check_output', side_effect=['24', 'x86_64']), \
                     patch('compatibility.subprocess.Popen') as logger, \
                     patch('compatibility.subprocess.run', side_effect=error) as execute:
                    with self.assertRaisesRegex(RuntimeError, expected):
                        compatibility.run('fixture')
                    self.assertEqual(1, execute.call_count)
                    logger.return_value.terminate.assert_called_once()
                results = base / 'results/api-24-x86_64-fixture'
                report = json.loads((results / 'report.json').read_text())
                self.assertFalse(report['passed'])
                self.assertEqual(expected, report['error'])
                self.assertEqual('install', report['stage'])
                self.assertEqual([], report['runs'])
                self.assertTrue((results / 'logcat.txt').exists())
                self.assertTrue((results / 'install.txt').exists())


class SdkDiscoveryTests(unittest.TestCase):
    def test_pinned_ndk_uses_gradle_sdk_without_environment(self):
        import os
        from pathlib import Path
        import tempfile
        import artifacts
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sdk = root / 'SDK with spaces'
            tool = sdk / 'ndk' / '30.0.0' / 'toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf'
            tool.parent.mkdir(parents=True)
            tool.touch()
            (root / 'local.properties').write_text(f'sdk.dir={sdk}\n')
            (root / 'ANDROID_NDK_VERSION').write_text('30.0.0\n')
            with patch.object(artifacts, 'ROOT', root), patch.dict(os.environ, {}, clear=True), patch('artifacts.shutil.which', return_value=None):
                self.assertEqual(str(tool), artifacts.readelf_tool())
                tool.unlink()
                with self.assertRaisesRegex(RuntimeError, 'pinned NDK'):
                    artifacts.readelf_tool()

    def test_sdk_environment_fallback_and_gradle_precedence(self):
        import os
        from pathlib import Path
        import tempfile
        from sdk import sdk_root
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.dict(os.environ, {'ANDROID_SDK_ROOT': '/sdk-from-root'}, clear=True):
                self.assertEqual(Path('/sdk-from-root'), sdk_root(root))
                os.environ['ANDROID_HOME'] = '/sdk-from-home'
                self.assertEqual(Path('/sdk-from-home'), sdk_root(root))
                (root / 'local.properties').write_text('sdk.dir=/sdk-from-gradle\n')
                self.assertEqual(Path('/sdk-from-gradle'), sdk_root(root))
            (root / 'local.properties').unlink()
            with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(RuntimeError, 'mise run android-sdk'):
                sdk_root(root)


class RegularAndroidSuiteTests(unittest.TestCase):
    def test_normal_task_only_selects_the_core_harness(self):
        import os
        from pathlib import Path
        import subprocess
        import tempfile
        root_script = Path(__file__).resolve().parents[2] / 'mise-tasks/test/android'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Tools').mkdir()
            (root / 'Tools/dal.sh').write_text('set -euo pipefail\ndal_require_swift_packages() { :; }\ndal_android_abis() { echo arm64-v8a; }\n')
            staged = root / 'androidtest/src/main/jniLibs/arm64-v8a'
            staged.mkdir(parents=True)
            (staged / 'libCoreAndroidTests.so').touch()
            adb = root / 'sdk/platform-tools/adb'
            adb.parent.mkdir(parents=True)
            adb.write_text('#!/bin/sh\nprintf "List of devices attached\\nfixture-device\\tdevice\\n"\n')
            adb.chmod(0o755)
            gradle = root / 'gradlew'
            gradle.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$DAL_TEST_ARGUMENTS"\n')
            gradle.chmod(0o755)
            arguments = root / 'arguments.txt'
            environment = dict(os.environ, MISE_PROJECT_ROOT=str(root), ANDROID_HOME=str(root / 'sdk'),
                               usage_no_stage='1', usage_core_only='1', DAL_TEST_ARGUMENTS=str(arguments))
            subprocess.run(['bash', str(root_script)], cwd=root, env=environment, check=True)
            actual = arguments.read_text().splitlines()
            self.assertIn(':androidtest:connectedAndroidTest', actual)
            self.assertIn('-Pandroid.testInstrumentationRunnerArguments.class=ai.desertant.core.androidtest.CoreBridgeTest', actual)


if __name__ == '__main__':
    unittest.main()
