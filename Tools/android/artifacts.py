#!/usr/bin/env python3
"""Inspect the actual AAR payload, including ICU data in stripped ELF files."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile
from sdk import sdk_root

ROOT = Path(__file__).resolve().parents[2]


def elf_symbols(output, undefined):
    symbols = set()
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[0].endswith(':') and (fields[6] == 'UND') == undefined:
            name, separator, version = fields[7].partition('@')
            if separator and version.lstrip('@').startswith('LIBC'):
                symbols.add((name, version.lstrip('@')))
    return symbols


def inspect_harness(apk):
    """Reject versioned Bionic imports absent from the declared minimum SDK."""
    catalog = (ROOT / 'gradle/libs.versions.toml').read_text()
    minimum = int(re.search(r'^minSdk\s*=\s*"(\d+)"', catalog, re.MULTILINE)[1])
    ndk = sdk_root(ROOT) / 'ndk' / (ROOT / 'ANDROID_NDK_VERSION').read_text().strip()
    tool = readelf_tool()
    report = {'minSdk': minimum, 'libraries': {}}
    triples = {'arm64-v8a': 'aarch64-linux-android', 'x86_64': 'x86_64-linux-android'}
    with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory() as temporary:
        for abi, triple in triples.items():
            names = [f'lib/{abi}/lib{product}.so' for product in ('CoreAndroidTests', 'UnicodeAndroidTests')]
            if not any(name in archive.namelist() for name in names):
                continue
            allowed = set()
            for library in ('libc.so', 'libm.so', 'libdl.so'):
                candidates = list(ndk.glob(f'toolchains/llvm/prebuilt/*/sysroot/usr/lib/{triple}/{minimum}/{library}'))
                if len(candidates) != 1:
                    raise RuntimeError(f'Missing unambiguous API {minimum} NDK stub for {abi}/{library}')
                allowed |= elf_symbols(subprocess.check_output([tool, '--dyn-syms', '--wide', str(candidates[0])], text=True), False)
            for name in names:
                path = Path(temporary) / Path(name).name
                path.write_bytes(archive.read(name))
                imported = elf_symbols(subprocess.check_output([tool, '--dyn-syms', '--wide', str(path)], text=True), True)
                missing = sorted(imported - allowed)
                if missing:
                    symbols = ', '.join(f'{symbol}@{version}' for symbol, version in missing)
                    raise RuntimeError(f'{name} imports Bionic symbols unavailable on API {minimum}: {symbols}; rebuild and stage the current harness')
                report['libraries'][name] = {'checkedBionicImports': len(imported)}
    if not report['libraries']:
        raise RuntimeError('No native test harness found in the compatibility APK')
    return report


def readelf_tool():
    tool = shutil.which('llvm-readelf')
    if tool:
        return tool
    sdk = sdk_root(ROOT)
    ndk = sdk / 'ndk' / (ROOT / 'ANDROID_NDK_VERSION').read_text().strip()
    candidates = sorted(ndk.glob('toolchains/llvm/prebuilt/*/bin/llvm-readelf'))
    if not candidates:
        raise RuntimeError(f"llvm-readelf is missing from the pinned NDK at {ndk}; run 'mise run android-sdk'")
    return str(candidates[0])


def inspect(data, name, tool):
    problems = []
    if re.search(rb'icudt\d+[lb]/|icudt\d+_dat', data):
        problems.append('bundled ICU data')
    if re.search(r'lib(?:icu|FoundationICU)', name, re.I):
        problems.append('bundled ICU library')
    with tempfile.NamedTemporaryFile(suffix='.so') as f:
        f.write(data)
        f.flush()
        dynamic = subprocess.check_output([tool, '-d', f.name], text=True)
        headers = subprocess.check_output([tool, '--program-headers', '--wide', f.name], text=True)
    segments = []
    for line in headers.splitlines():
        fields = line.split()
        if fields and fields[0] == 'LOAD':
            offset, address, alignment = (int(fields[index], 16) for index in (1, 2, -1))
            segments.append({'offset': offset, 'virtualAddress': address, 'alignment': alignment})
            if alignment < 16384 or (address - offset) % 16384:
                problems.append('ELF LOAD segment is not 16 KB aligned')
    if not segments:
        problems.append('no ELF LOAD segments')
    needed = re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic)
    if any(re.match(r'lib(?:icu|Foundation)', lib, re.I) for lib in needed):
        problems.append('ICU/Foundation dynamic dependency')
    return {'bytes': len(data), 'needed': needed, 'loadSegments': segments, 'problems': problems}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--abis', nargs='+', default=['arm64-v8a', 'x86_64'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--model', default='all')
    parser.add_argument('--baseline', action='store_true', help='Record existing violations without accepting them')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    models = [m for m in manifest['models'] if m['sdks'].get('kotlin', {}).get('status') == 'live'
              and (ROOT / 'packages' / (m['id'] + '-kotlin') / 'src/main/AndroidManifest.xml').exists()]
    tool = readelf_tool()
    report = {'schema': 1, 'baseline': args.baseline, 'abis': args.abis, 'artifacts': [], 'errors': []}
    paths = [('core', 'kotlin/build/outputs/aar/core-release.aar')]
    paths += [(m['id'], f"packages/{m['id']}-kotlin/build/outputs/aar/{m['id']}-kotlin-release.aar") for m in models if args.model in ('all', m['id'])]
    for model, pattern in paths:
        path = ROOT / pattern
        if not path.exists() and model != 'core':
            candidates = list((ROOT / 'packages' / (model + '-kotlin') / 'build/outputs/aar').glob('*-release.aar'))
            if len(candidates) == 1:
                path = candidates[0]
        entry = {'model': model, 'aar': str(path.relative_to(ROOT)), 'libraries': {}}
        if not path.is_file():
            report['errors'].append(f'{model}: missing release AAR')
            continue
        entry['compressedBytes'] = path.stat().st_size
        with zipfile.ZipFile(path) as aar:
            for abi in args.abis:
                names = [n for n in aar.namelist() if n.startswith(f'jni/{abi}/') and n.endswith('.so')]
                if not names:
                    report['errors'].append(f'{model}: missing {abi}')
                for name in names:
                    result = inspect(aar.read(name), name, tool)
                    result['compressedBytes'] = aar.getinfo(name).compress_size
                    entry['libraries'][name] = result
                    report['errors'] += [f'{model}/{name}: {p}' for p in result['problems']]
        report['artifacts'].append(entry)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Inspected {len(report['artifacts'])} AARs; {len(report['errors'])} violations. Report: {args.output}")
    if report['errors'] and not args.baseline:
        raise SystemExit('\n'.join(report['errors']))


if __name__ == '__main__':
    main()
