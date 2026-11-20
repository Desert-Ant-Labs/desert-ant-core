#!/usr/bin/env python3
"""Capture a bounded environment snapshot after an Android CI failure."""
import argparse
import os
from pathlib import Path
import subprocess
import time


def capture(path, command):
    with path.open('w') as output:
        output.write(f'\n{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        output.flush()
        try:
            subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=10, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            output.write(f'\n{type(error).__name__}: {error}\n')


def collect(directory, avd):
    directory.mkdir(parents=True, exist_ok=True)
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
    adb = str(sdk / 'platform-tools/adb')
    tools = sdk / 'cmdline-tools/latest/source.properties'
    if tools.is_file():
        (directory / 'command-line-tools.txt').write_text(tools.read_text())
    capture(directory / 'adb-version.txt', [adb, 'version'])
    capture(directory / 'emulator-version.txt', [str(sdk / 'emulator/emulator'), '-version'])
    capture(directory / 'acceleration.txt', [str(sdk / 'emulator/emulator'), '-accel-check'])
    capture(directory / 'host.txt', ['uname', '-a'])
    capture(directory / 'cpu.txt', ['lscpu'])
    capture(directory / 'kvm.txt', ['ls', '-l', '/dev/kvm'])
    for filename, command in (
        ('memory.txt', ['free', '-m']),
        ('disk.txt', ['df', '-h', str(directory), str(sdk)]),
        ('devices.txt', [adb, 'devices', '-l']),
    ):
        capture(directory / filename, command)
    for name in ('memory.events', 'memory.current', 'memory.max'):
        path = Path('/sys/fs/cgroup') / name
        if path.is_file():
            (directory / name).write_text(path.read_text())
    home = Path(os.environ.get('ANDROID_AVD_HOME') or
                str(Path(os.environ.get('ANDROID_USER_HOME', str(Path.home() / '.android'))) / 'avd'))
    ini = home / (avd + '.ini')
    if ini.is_file():
        (directory / 'avd.ini').write_text(ini.read_text())
    config = home / (avd + '.avd/config.ini')
    if config.is_file():
        lines = [line for line in config.read_text().splitlines()
                 if line.startswith(('hw.cpu.', 'hw.ramSize=', 'vm.heapSize=', 'image.sysdir.', 'disk.dataPartition.size=', 'hw.gpu.'))]
        (directory / 'avd-config.txt').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--avd', required=True)
    args = parser.parse_args()
    collect(args.output, args.avd)
