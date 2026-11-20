#!/usr/bin/env python3
"""Prepare once, then execute the identical test APK on explicit Android devices."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from sdk import sdk_root
from artifacts import inspect_harness

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / '.build/android-unicode'
PACKAGE = 'ai.desertant.core.androidtest.test'
RUNNER = PACKAGE + '/ai.desertant.androidtest.HubTestRunner'
TARGET_SDK = 37


def apk_target_sdk(apk):
    tool = sdk_root(ROOT) / 'build-tools/36.0.0/aapt2'
    if sys.platform == 'win32':
        tool = tool.with_suffix('.exe')
    badging = subprocess.check_output([str(tool), 'dump', 'badging', str(apk)], text=True)
    match = re.search(r"^targetSdkVersion:'(\d+)'$", badging, re.MULTILINE)
    if not match:
        raise RuntimeError('APK has no numeric target SDK')
    target = int(match[1])
    if target != TARGET_SDK:
        raise RuntimeError(f'Compatibility APK targets API {target}, expected {TARGET_SDK}')
    return target


def metadata():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    models = [m for m in manifest['models'] if m['sdks'].get('kotlin', {}).get('status') == 'live']
    # Product names come from the catalog, not the human-readable model name.
    libraries = []
    for model in models:
        directory = ROOT / 'packages' / (model['id'] + '-kotlin')
        if not (directory / 'src/main/AndroidManifest.xml').exists():
            continue
        for candidate in (ROOT / 'Sources').glob('*/Catalog.swift'):
            contents = candidate.read_text()
            if re.search(r'let id = "' + re.escape(model['id']) + '"', contents):
                product = re.search(r'let product = "([^"]+)"', contents)
                if product:
                    libraries.append(product[1] + 'Android')
                    break
        else:
            raise RuntimeError('No catalog product for ' + model['id'])
    assert libraries, 'No native models discovered'
    return {'schema': 1, 'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
            'libraries': libraries, 'models': [{'id': m['id'], 'weights': m.get('weights')} for m in models]}


def prepare(abi="all"):
    prepared = BASE / 'prepared'
    prepared.mkdir(parents=True, exist_ok=True)
    meta = BASE / 'metadata'
    meta.mkdir(parents=True, exist_ok=True)
    info = metadata()
    (meta / 'compatibility-build.json').write_text(json.dumps(info, indent=2) + '\n')
    command = ['./gradlew', '--no-daemon', ':androidtest:assembleDebugAndroidTest']
    if abi != 'all':
        command.append('-PdalCompatibilityAbi=' + abi)
    subprocess.run(command, cwd=ROOT, check=True)
    candidates = list((ROOT / 'androidtest/build/outputs/apk/androidTest/debug').glob('*.apk'))
    if len(candidates) != 1:
        raise RuntimeError(f'Expected one instrumentation APK, found {candidates}')
    info['targetSdk'] = apk_target_sdk(candidates[0])
    info['harness'] = inspect_harness(candidates[0])
    shutil.copy2(candidates[0], prepared / 'test.apk')
    info['apkSha256'] = hashlib.sha256((prepared / 'test.apk').read_bytes()).hexdigest()
    (prepared / 'build.json').write_text(json.dumps(info, indent=2) + '\n')
    for name in ('artifacts.json', 'baseline.json'):
        if (BASE / name).exists():
            shutil.copy2(BASE / name, prepared / name)
    print(f'Prepared {prepared}')


def successful(output):
    found = re.search(r'OK \((\d+) tests?\)', output)
    forbidden = ('FAILURES!!!', 'INSTRUMENTATION_FAILED', 'Process crashed', 'shortMsg=', 'INSTRUMENTATION_ABORTED', 'INSTRUMENTATION_STATUS_CODE: -1', 'INSTRUMENTATION_STATUS_CODE: -2', 'INSTRUMENTATION_STATUS_CODE: -3', 'INSTRUMENTATION_STATUS_CODE: -4')
    return int(found[1]) if found and int(found[1]) > 0 and not any(s in output for s in forbidden) else 0


def runtime_metadata(output):
    return [json.loads(match) for match in re.findall(
        r'^INSTRUMENTATION_STATUS: dalUnicodeRuntime=(\{[^\n]+\})\r?$', output, re.MULTILINE
    )]


def valid_runtime(records, api, abi):
    return bool(records) and all(
        record.get('api') == api and record.get('abi') == abi
        and isinstance(record.get('icu'), str) and bool(record['icu'])
        and isinstance(record.get('unicode'), str) and bool(record['unicode'])
        for record in records
    )


def run(serial):
    adb = shutil.which('adb') or str(sdk_root(ROOT) / 'platform-tools/adb')
    if not serial:
        serial = os.environ.get('ANDROID_SERIAL')
    if not serial:
        lines = subprocess.check_output([adb, 'devices'], text=True).splitlines()[1:]
        devices = [line.split()[0] for line in lines if line.endswith('\tdevice')]
        if len(devices) != 1:
            raise RuntimeError('Select exactly one device with --serial; connected: ' + ', '.join(devices))
        serial = devices[0]
    command = [adb, '-s', serial]
    def shell(*args):
        return subprocess.check_output(command + ['shell', *args], text=True, timeout=30).strip()
    api = int(shell('getprop', 'ro.build.version.sdk'))
    abi = shell('getprop', 'ro.product.cpu.abi')
    report_dir = BASE / 'results' / f'api-{api}-{abi}-{re.sub(r"[^A-Za-z0-9_.-]", "_", serial)}'
    report_dir.mkdir(parents=True, exist_ok=True)
    info = json.loads((BASE / 'prepared/build.json').read_text())
    if hashlib.sha256((BASE / 'prepared/test.apk').read_bytes()).hexdigest() != info['apkSha256']:
        raise RuntimeError('Prepared APK does not match its build metadata')
    if info.get('targetSdk') != TARGET_SDK:
        raise RuntimeError('Prepare a compatibility APK targeting API 37 before running')
    report = {'schema': 1, 'api': api, 'abi': abi, 'serial': serial, 'build': info, 'runs': [], 'runtime': [], 'passed': False}
    with (report_dir / 'logcat.txt').open('w') as log:
        logging = subprocess.Popen(command + ['logcat', '-v', 'threadtime', '-T', '1', 'DAL_UNICODE:I', 'AndroidRuntime:E', 'DEBUG:F', 'PackageManager:I', 'PackageInstaller:I', 'installd:I', 'dex2oat:I', '*:S'], stdout=log, stderr=subprocess.STDOUT)
        try:
            report['stage'] = 'install'
            with (report_dir / 'install.txt').open('w') as installation:
                subprocess.run(command + ['install', '-r', '-t', str(BASE / 'prepared/test.apk')],
                               stdout=installation, stderr=subprocess.STDOUT, check=True, timeout=180)
            report['stage'] = 'instrumentation'
            selections = [('NativeLibraryCompatibilityTest', library) for library in info['libraries']]
            selections += [('UnicodeCompatibilityTest', None), ('UnicodeModelTest', None)]
            for index, (test, library) in enumerate(selections):
                arguments = ['-e', 'class', 'ai.desertant.core.androidtest.' + test]
                if library:
                    arguments += ['-e', 'nativeLibrary', library]
                for name in ('HF_TOKEN', 'DAL_HF_REPO_SUFFIX', 'DAL_LICENSE_ENDPOINT'):
                    if os.environ.get(name):
                        arguments += ['-e', name, os.environ[name]]
                started = time.monotonic()
                # Never print the command: instrumentation arguments can contain a Hub token.
                result = subprocess.run(command + ['shell', 'am', 'instrument', '-w', '-r', *arguments, RUNNER], capture_output=True, text=True, timeout=900)
                output = result.stdout + result.stderr
                (report_dir / f'{index:02}-{library or test}.txt').write_text(output)
                report['runtime'].extend(runtime_metadata(output))
                count = successful(output)
                report['runs'].append({'suite': test, 'library': library, 'tests': count,
                                       'seconds': round(time.monotonic() - started, 2), 'passed': result.returncode == 0 and count > 0})
                print(f'{test} {library or ""}: {count} tests', flush=True)
            report['passed'] = all(item['passed'] for item in report['runs'])
            report['stage'] = 'complete'
        except subprocess.TimeoutExpired as error:
            # Instrumentation arguments can contain credentials, so omit the command.
            report['error'] = f"{report['stage']} timed out after {error.timeout} seconds"
            raise RuntimeError(report['error']) from None
        except subprocess.CalledProcessError as error:
            report['error'] = f"{report['stage']} exited with code {error.returncode}"
            raise RuntimeError(report['error']) from None
        finally:
            logging.terminate()
            try: logging.wait(timeout=10)
            except subprocess.TimeoutExpired: logging.kill(); logging.wait()
            report['tests'] = sum(item['tests'] for item in report['runs'])
            if not valid_runtime(report['runtime'], api, abi):
                report['passed'] = False
                report.setdefault('error', 'Missing or inconsistent runtime metadata in instrumentation results')
            (report_dir / 'report.json').write_text(json.dumps(report, indent=2) + '\n')

    if not report['passed']:
        raise RuntimeError(f'Compatibility checks failed; see {report_dir}')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'run'])
    parser.add_argument('--serial')
    parser.add_argument('--abi', choices=['arm64-v8a', 'x86_64', 'all'], default='all', help='ABI to package when preparing the test APK')
    args = parser.parse_args()
    if args.action == 'prepare': prepare(args.abi)
    else: run(args.serial)


if __name__ == '__main__':
    main()
