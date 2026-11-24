"""The size gate must reject unpacked libraries and stale provenance."""
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from native_size import attribution, link_map, relocations, sha256
from compare_sizes import apk_sizes, compare
from artifacts import ci_identity, publish_ci_summary


def elf(packed=True, magic=b'APS2payload', tagged=True, relr=False, unpacked=False):
    names = b'\0.shstrtab\0.android.rela.dyn\0.rela.plt\0.dynamic\0.relr.dyn\0'
    payloads = [b'', names, magic, b'\0' * 24, b'', b'\0' * 8]
    tags = [(0x60000011, 0x1000), (0x60000012, len(magic))] if packed and tagged else []
    if not packed or unpacked:
        tags += [(8, len(magic))]
    payloads[4] = b''.join(struct.pack('<qQ', *tag) for tag in tags + [(0, 0)])
    types = [0, 3, 0x60000002 if packed else 4, 4, 6, 19 if relr else 1]
    offsets, data = [], bytearray(64)
    for payload in payloads:
        offsets.append(len(data))
        data.extend(payload)
    table_offset = len(data)
    for index, name in enumerate(('', '.shstrtab', '.android.rela.dyn', '.rela.plt', '.dynamic', '.relr.dyn')):
        data.extend(struct.pack('<IIQQQQIIQQ', names.index(name.encode()) if name else 0,
                                types[index], 2, 0x1000 if index == 2 else 0,
                                offsets[index], len(payloads[index]), 0, 0, 8, 0))
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<Q', data, 40, table_offset)
    struct.pack_into('<HHH', data, 58, 64, len(payloads), 1)
    return bytes(data)


MAP = '''             VMA              LMA     Size Align Out     In      Symbol
1000 1000 100 16 .text
1000 1000 20 4         /sdk with spaces/libswiftCore.a(Swift.o):(.text)
1020 1020 10 4         /tmp/random/libc++.a(vector.cpp.o):(.text)
1030 1030 8 4          /sdk/libclang_rt.builtins-aarch64-android.a(a.o):(.text)
1038 1038 10 4         /build/Objects-normal/aarch64/Emo.o:(.text)
1048 1048 10 4         <internal>:(.text)
1058 1058 8 4                  swift::Thing<ctypes::Name>::method():(argument)
2000 2000 100 16 .bss
2000 2000 100 4         /sdk/libswiftCore.a(Swift.o):(.bss)
0 0 100 1 .debug_info
0 0 100 1          /sdk/libswiftCore.a(Swift.o):(.debug_info)
'''


class RelocationTests(unittest.TestCase):
    def test_packed_payload_tags_and_plt(self):
        result = relocations(elf())
        self.assertEqual([], result['problems'])
        self.assertEqual(11, result['packedBytes'])
        self.assertIn('.rela.plt', result['sections'])

    def test_missing_corrupt_and_newer_formats_fail(self):
        for data in (elf(False), elf(magic=b'bad!payload'), elf(tagged=False), elf(relr=True), elf(unpacked=True)):
            with self.subTest(data=data):
                self.assertTrue(relocations(data)['problems'])
        for data in (b'', b'not an elf', elf()[:80]):
            with self.assertRaises(ValueError):
                relocations(data)


class MapTests(unittest.TestCase):
    def test_contributions_exclude_debug_bss_and_symbol_lines(self):
        result = link_map(MAP)
        self.assertEqual({'libswiftCore.a': 32, 'libc++.a': 16, 'libclang_rt.builtins-android.a': 8}, result['archives'])
        self.assertEqual({'Emo': 16}, result['modules'])
        self.assertEqual(16, result['linkerGeneratedBytes'])
        self.assertEqual(result, link_map(MAP.replace('aarch64', 'x86_64')))
        self.assertEqual(result, link_map(MAP.replace('/build/Objects-normal/aarch64/Emo.o', '/build/release/Emo.build/Words.swift.o')))
        for text in ('', 'VMA LMA Size Align Out In Symbol\n'):
            with self.assertRaises(ValueError):
                link_map(text)

    def test_missing_stale_and_unreviewed_reports_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(FileNotFoundError):
                attribution(directory, b'library', [])
            (directory / 'link.map').write_text(MAP)
            metadata = {'librarySha256': sha256(b'library'), 'mapSha256': sha256(MAP.encode())}
            (directory / 'build.json').write_text(json.dumps(metadata))
            self.assertIn('unreviewed runtime archive: libswiftCore.a', attribution(directory, b'library', [])['problems'])
            self.assertEqual([], attribution(directory, b'library', link_map(MAP)['archives'])['problems'])
            with self.assertRaisesRegex(ValueError, 'does not match'):
                attribution(directory, b'other library', [])
            (directory / 'link.map').write_text(MAP + '\n')
            with self.assertRaisesRegex(ValueError, 'does not match'):
                attribution(directory, b'library', [])


class ArtifactIntegrationTests(unittest.TestCase):
    def test_gate_checks_the_aar_payload_and_provenance(self):
        import artifacts
        cases = ((True, True, False, True), (False, True, False, False),
                 (True, True, True, False), (True, False, False, False))
        for packed, vendor_packed, stale, accepted in cases:
            with self.subTest(packed=packed, vendor_packed=vendor_packed, stale=stale), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'manifest.json').write_text(json.dumps({'models': [{'id': 'title', 'sdks': {'kotlin': {'status': 'live'}}}]}))
                source = root / 'packages/title-kotlin/src/main'
                source.mkdir(parents=True)
                (source / 'AndroidManifest.xml').touch()
                config = root / 'Tools/android'
                config.mkdir(parents=True)
                (config / 'runtime-archives.json').write_text(json.dumps({'title': list(link_map(MAP)['archives'])}))
                data = elf(packed)
                model_path = 'jni/arm64-v8a/libTitleAndroid.so'
                vendor_path = 'jni/arm64-v8a/liblitert-lm.so'
                vendor = elf(vendor_packed, magic=b'APS2vendor')
                for directory, name in ((root / 'kotlin/build/outputs/aar', 'core-release.aar'),
                                        (root / 'packages/title-kotlin/build/outputs/aar', 'title-kotlin-release.aar')):
                    directory.mkdir(parents=True)
                    with zipfile.ZipFile(directory / name, 'w') as archive:
                        archive.writestr(model_path, data)
                        if name == 'title-kotlin-release.aar':
                            archive.writestr(vendor_path, vendor)
                report_dir = root / '.build-android/reports/title/arm64-v8a'
                report_dir.mkdir(parents=True)
                (report_dir / 'link.map').write_text(MAP)
                (report_dir / 'build.json').write_text(json.dumps({'librarySha256': sha256(b'stale' if stale else data),
                                                                 'mapSha256': sha256(MAP.encode())}))
                output = root / 'artifacts.json'
                argv = ['artifacts.py', '--abis', 'arm64-v8a', '--output', str(output)]
                with patch.object(artifacts, 'ROOT', root), patch('sys.argv', argv), \
                     patch('artifacts.readelf_tool', return_value='readelf'), \
                     patch('artifacts.subprocess.check_output', return_value='commit'), \
                     patch('artifacts.inspect', side_effect=lambda data, *_: {'bytes': len(data), 'problems': []}):
                    if accepted:
                        artifacts.main()
                    else:
                        with self.assertRaises(SystemExit):
                            artifacts.main()
                report = json.loads(output.read_text())
                self.assertEqual(accepted, not report['errors'])
                libraries = report['artifacts'][1]['libraries']
                self.assertEqual(sha256(data), libraries[model_path]['sha256'])
                self.assertEqual(sha256(vendor), libraries[vendor_path]['sha256'])
                self.assertNotIn('attribution', libraries[vendor_path])


class CiReportTests(unittest.TestCase):
    def test_only_this_job_attempt_can_publish_even_after_a_build_failure(self):
        identity = dict(zip(('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'GITHUB_SHA'),
                            ('123', '2', 'prepare', 'current-commit')))
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'artifacts.json'
            summary = directory / 'summary.md'
            path.with_suffix('.md').write_text('current size report\n')
            env = identity | {'GITHUB_STEP_SUMMARY': str(summary)}
            with patch.dict(os.environ, env, clear=True):
                self.assertEqual(identity, ci_identity())
                self.assertFalse(publish_ci_summary(path))
                for key in identity:
                    stale = identity | {key: 'previous'}
                    path.write_text(json.dumps({'ci': stale}))
                    self.assertFalse(publish_ci_summary(path))
                path.write_text(json.dumps({'commit': 'current-commit'}))
                self.assertFalse(publish_ci_summary(path))
                self.assertFalse(summary.exists())
                path.write_text(json.dumps({'ci': identity, 'errors': ['build violation']}))
                self.assertTrue(publish_ci_summary(path))
                self.assertEqual('current size report\n', summary.read_text())
            with patch.dict(os.environ, {}, clear=True):
                self.assertIsNone(ci_identity())
                self.assertFalse(publish_ci_summary(path))

    def test_summary_command_marks_missing_reports_unavailable_without_sdk_setup(self):
        import artifacts
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / 'step-output'
            argv = ['artifacts.py', '--ci-summary', '--output', str(directory / 'missing.json')]
            with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output)}, clear=True), \
                 patch('sys.argv', argv), patch('artifacts.readelf_tool', side_effect=AssertionError('SDK should not be needed')):
                artifacts.main()
            self.assertEqual('available=false\n', output.read_text())


class ComparisonTests(unittest.TestCase):
    def report(self, size):
        return {'manifestSha256': 'same', 'artifacts': [{'model': 'emo', 'libraries': {'jni/arm64-v8a/libEmoAndroid.so': {
            'bytes': size, 'compressedBytes': size // 2, 'relocations': {'bytes': size // 4},
            'attribution': {'archives': {'libswiftCore.a': 12}, 'modules': {'Emo': 8},
                            'build': dict.fromkeys(('swift', 'ndk', 'api', 'litert'), 'pinned')},
        }}}]}

    def test_apk_measurement_requires_the_same_native_payload(self):
        report = self.report(100)
        library = next(iter(report['artifacts'][0]['libraries'].values()))
        library['sha256'] = sha256(b'library')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'consumer.apk'
            for data, accepted in ((b'library', True), (b'other library', False)):
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('lib/arm64-v8a/libEmoAndroid.so', data)
                if accepted:
                    self.assertEqual(7, apk_sizes(path, report)['abis']['arm64-v8a']['nativeBytes'])
                else:
                    with self.assertRaisesRegex(ValueError, 'differs'):
                        apk_sizes(path, report)

    def test_core_runtime_must_be_byte_identical(self):
        before = self.report(100)
        core = {'bytes': 100, 'compressedBytes': 50, 'relocations': {'bytes': 24}, 'sha256': 'same-runtime'}
        before['artifacts'].append({'model': 'core', 'libraries': {'jni/arm64-v8a/libLiteRt.so': core}})
        for size, digest in ((100, 'same-runtime'), (100, 'different-runtime'),
                             (900, 'different-runtime'), (80, 'different-runtime'), (100, None)):
            after = self.report(80)
            after['artifacts'].append({'model': 'core', 'libraries': {
                'jni/arm64-v8a/libLiteRt.so': core | {'bytes': size, 'sha256': digest}}})
            with self.subTest(size=size, digest=digest):
                if digest == 'same-runtime':
                    rows = compare(before, after)
                    self.assertEqual(0, next(row for row in rows if row['model'] == 'core')['savedBytes'])
                else:
                    with self.assertRaisesRegex(ValueError, 'core runtime binary changed'):
                        compare(before, after)

    def test_saving_and_uncontrolled_comparisons(self):
        self.assertEqual(20, compare(self.report(100), self.report(80))[0]['savedBytes'])
        with self.assertRaisesRegex(ValueError, 'did not shrink'):
            compare(self.report(100), self.report(100))
        for mutation in ('models', 'manifest', 'pin', 'archive'):
            report = self.report(80)
            library = next(iter(report['artifacts'][0]['libraries'].values()))
            if mutation == 'models':
                report['artifacts'] = []
            elif mutation == 'manifest':
                report['manifestSha256'] = 'different'
            elif mutation == 'pin':
                library['attribution']['build']['swift'] = 'different'
            else:
                library['attribution']['archives']['libswiftCore.a'] = 13
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                compare(self.report(100), report)

    def test_title_runtime_must_be_byte_identical(self):
        before, after = self.report(100), self.report(80)
        path = 'jni/arm64-v8a/liblitert-lm.so'
        for report in (before, after):
            report['artifacts'].append({'model': 'title', 'libraries': {path: {
                'bytes': 100, 'compressedBytes': 50, 'relocations': {'bytes': 24}, 'sha256': 'same-runtime',
            }}})
        self.assertEqual(0, next(row for row in compare(before, after) if row['model'] == 'title')['savedBytes'])
        after['artifacts'][-1]['libraries'][path]['sha256'] = 'different-runtime'
        with self.assertRaisesRegex(ValueError, 'title runtime binary changed'):
            compare(before, after)


if __name__ == '__main__':
    unittest.main()
