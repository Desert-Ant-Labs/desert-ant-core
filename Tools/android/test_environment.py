"""Exercise upgrades of persistent SDKs and rejection of malformed AVDs."""
import hashlib
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import environment


class ToolsProvisioningTests(unittest.TestCase):
    def make_tools(self, directory, version):
        (directory / 'bin').mkdir(parents=True)
        (directory / 'source.properties').write_text(f'Pkg.Revision={version}\n')
        suffix = '.bat' if sys.platform == 'win32' else ''
        for name in ('sdkmanager', 'avdmanager'):
            tool = directory / 'bin' / (name + suffix)
            tool.touch()
            tool.chmod(0o755)

    def fixture(self, root):
        archive = root / 'tools.zip'
        suffix = '.bat' if sys.platform == 'win32' else ''
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('cmdline-tools/source.properties', 'Pkg.Revision=22.0\n')
            for name in ('sdkmanager', 'avdmanager'):
                bundle.writestr('cmdline-tools/bin/' + name + suffix, '#!/bin/sh\n')
        return archive, hashlib.sha1(archive.read_bytes()).hexdigest()

    def test_fresh_and_old_sdks_install_verified_tools_and_then_reuse_them(self):
        for existing in (None, '12.0'):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                sdk = root / 'SDK with spaces'
                latest = sdk / 'cmdline-tools/latest'
                if existing:
                    self.make_tools(latest, existing)
                archive, checksum = self.fixture(root)
                with patch.dict('os.environ', {}, clear=True), \
                     patch.dict(environment.ARCHIVES, {sys.platform: ('fixture', checksum)}), \
                     patch('environment.urllib.request.urlretrieve', side_effect=lambda _, target: shutil.copy2(archive, target)) as fetch:
                    self.assertEqual(latest, environment.provision(sdk))
                    self.assertEqual((22, 0), environment.tools_version(latest))
                    environment.provision(sdk)
                    self.assertEqual(1, fetch.call_count)

    def test_bad_download_preserves_existing_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = root / 'sdk/cmdline-tools/latest'
            self.make_tools(latest, '12.0')
            archive, _ = self.fixture(root)
            with patch.dict('os.environ', {}, clear=True), \
                 patch.dict(environment.ARCHIVES, {sys.platform: ('fixture', 'invalid-checksum')}), \
                 patch('environment.urllib.request.urlretrieve', side_effect=lambda _, target: shutil.copy2(archive, target)):
                with self.assertRaisesRegex(RuntimeError, 'checksum'):
                    environment.provision(root / 'sdk')
            self.assertEqual((12, 0), environment.tools_version(latest))

    def test_failed_replacement_restores_existing_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = root / 'sdk/cmdline-tools/latest'
            self.make_tools(latest, '12.0')
            archive, checksum = self.fixture(root)
            rename = Path.rename
            def fail_install(path, target):
                if path.name == 'cmdline-tools' and Path(target) == latest:
                    raise OSError('fixture replacement failed')
                return rename(path, target)
            with patch.dict('os.environ', {}, clear=True), \
                 patch.dict(environment.ARCHIVES, {sys.platform: ('fixture', checksum)}), \
                 patch('environment.urllib.request.urlretrieve', side_effect=lambda _, target: shutil.copy2(archive, target)), \
                 patch.object(Path, 'rename', fail_install):
                with self.assertRaisesRegex(OSError, 'replacement failed'):
                    environment.provision(root / 'sdk')
            self.assertEqual((12, 0), environment.tools_version(latest))


class AvdMetadataTests(unittest.TestCase):
    def test_invalid_target_and_wrong_image_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'fixture.avd'
            directory.mkdir()
            config = directory / 'config.ini'
            ini = root / 'fixture.ini'
            config.write_text('image.sysdir.1=system-images/android-37.0/google_apis/x86_64/\n')
            ini.write_text(f'path={directory}\ntarget=android-0\n')
            with self.assertRaisesRegex(RuntimeError, 'expected android-37.0'):
                environment.check_avd('fixture', 37, root)
            ini.write_text(f'path={directory}\ntarget=android-37.0\n')
            environment.check_avd('fixture', 37, root)
            config.write_text('image.sysdir.1=system-images/android-36/google_apis/x86_64/\n')
            with self.assertRaisesRegex(RuntimeError, 'system image'):
                environment.check_avd('fixture', 37, root)


if __name__ == '__main__':
    unittest.main()
