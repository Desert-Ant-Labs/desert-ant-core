#!/usr/bin/env python3
"""Provision tools that understand minor API versions and validate AVD metadata."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
import urllib.request
import zipfile

# Google's repository metadata pins revision 22.0 to this archive build.
TOOLS_VERSION = (22, 0)
TOOLS_BUILD = '15859902'
ARCHIVES = {
    'linux': ('linux', '040d3996a65543d22ec4bf73e4c37aa37a8d4af4'),
    'darwin': ('mac_x86_64', '1a79e61677b99cb0ce622792713cbea7ff2dc5de'),
    'win32': ('win', 'b9862337a13e2809a5159dc3a08d058091bd59f6'),
}


def properties(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines()
                if '=' in line and not line.lstrip().startswith('#'))


def tools_version(directory):
    source = directory / 'source.properties'
    suffix = '.bat' if sys.platform == 'win32' else ''
    if not source.is_file() or not all((directory / 'bin' / (name + suffix)).is_file()
                                      for name in ('sdkmanager', 'avdmanager')):
        return ()
    if sys.platform != 'win32' and not all(os.access(directory / 'bin' / name, os.X_OK)
                                          for name in ('sdkmanager', 'avdmanager')):
        return ()
    match = re.fullmatch(r'(\d+)\.(\d+)(?:\.\d+)?', properties(source).get('Pkg.Revision', ''))
    return (int(match[1]), int(match[2])) if match else ()


def provision(sdk):
    override = os.environ.get('DAL_ANDROID_CMDLINE_TOOLS', TOOLS_BUILD)
    if override != TOOLS_BUILD:
        raise RuntimeError(f'API 37 requires the pinned command-line tools build {TOOLS_BUILD}; remove DAL_ANDROID_CMDLINE_TOOLS={override}')
    latest = sdk / 'cmdline-tools/latest'
    version = tools_version(latest)
    # Bootstrap is pinned; keep a newer installation supplied by Android Studio.
    if version < TOOLS_VERSION:
        platform, checksum = ARCHIVES[sys.platform]
        latest.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.tools-install-', dir=latest.parent) as temporary:
            temporary = Path(temporary)
            archive = temporary / 'tools.zip'
            url = f'https://dl.google.com/android/repository/commandlinetools-{platform}-{TOOLS_BUILD}_latest.zip'
            print(f'Installing Android command-line tools 22.0 into {latest}', flush=True)
            urllib.request.urlretrieve(url, archive)
            if hashlib.sha1(archive.read_bytes()).hexdigest() != checksum:
                raise RuntimeError('Android command-line tools archive checksum mismatch')
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(temporary)
            extracted = temporary / 'cmdline-tools'
            for executable in (extracted / 'bin').iterdir():
                executable.chmod(0o755)
            if tools_version(extracted) != TOOLS_VERSION:
                raise RuntimeError('Downloaded command-line tools have an unexpected revision')
            backup = temporary / 'previous'
            if latest.exists() or latest.is_symlink():
                latest.rename(backup)
            try:
                extracted.rename(latest)
            except OSError:
                if backup.exists() or backup.is_symlink():
                    backup.rename(latest)
                raise
        version = tools_version(latest)
    print(f'Android command-line tools {version[0]}.{version[1]}: {latest}')
    return latest


def check_avd(name, api, home=None):
    if home is None:
        home = Path(os.environ.get('ANDROID_AVD_HOME') or
                    str(Path(os.environ.get('ANDROID_USER_HOME', str(Path.home() / '.android'))) / 'avd'))
    ini = properties(home / (name + '.ini'))
    expected = f'android-{api}' + ('.0' if api >= 37 else '')
    if ini.get('target') != expected:
        raise RuntimeError(f"AVD target is {ini.get('target')!r}, expected {expected}; update command-line tools and recreate the AVD")
    config = properties(Path(ini['path']) / 'config.ini')
    if f'system-images/{expected}/' not in config.get('image.sysdir.1', '').replace('\\', '/'):
        raise RuntimeError('AVD system image does not match its requested API')
    print(f"AVD {name}: target={expected}, RAM={config.get('hw.ramSize')}, data={config.get('disk.dataPartition.size')}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    install = commands.add_parser('provision')
    install.add_argument('--sdk', type=Path, required=True)
    avd = commands.add_parser('check-avd')
    avd.add_argument('--name', required=True)
    avd.add_argument('--api', type=int, required=True)
    args = parser.parse_args()
    if args.command == 'provision':
        provision(args.sdk)
    else:
        check_avd(args.name, args.api)
