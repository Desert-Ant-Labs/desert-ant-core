#!/usr/bin/env python3
"""Compare two artifact reports without rebuilding a baseline in CI."""
import argparse
import json
from pathlib import Path
import zipfile
from native_size import is_prebuilt_runtime, sha256


def libraries(report):
    return {(artifact['model'], name): library for artifact in report['artifacts']
            for name, library in artifact['libraries'].items()}


def compare(before, after):
    old, new = libraries(before), libraries(after)
    if not old or old.keys() != new.keys():
        raise ValueError('baseline and candidate must contain the same models and ABIs')
    if before['manifestSha256'] != after['manifestSha256']:
        raise ValueError('baseline and candidate use different model manifests')
    rows = []
    for key in sorted(old):
        a, b = old[key], new[key]
        if is_prebuilt_runtime(*key):
            if not a.get('sha256') or a['sha256'] != b.get('sha256'):
                raise ValueError(f'{key}: {key[0]} runtime binary changed between measurements')
        else:
            for pin in ('swift', 'ndk', 'api', 'litert'):
                if a['attribution']['build'][pin] != b['attribution']['build'][pin]:
                    raise ValueError(f'{key}: {pin} changed between measurements')
            if a['attribution']['archives'] != b['attribution']['archives']:
                raise ValueError(f'{key}: retained runtime archive contributions changed')
            if a['attribution']['modules'] != b['attribution']['modules']:
                raise ValueError(f'{key}: retained module contributions changed')
            if b['bytes'] >= a['bytes']:
                raise ValueError(f'{key}: packed library did not shrink')
        rows.append({'model': key[0], 'library': key[1], 'beforeBytes': a['bytes'], 'afterBytes': b['bytes'],
                     'savedBytes': a['bytes'] - b['bytes'], 'savedPercent': 100 * (a['bytes'] - b['bytes']) / a['bytes'],
                     'compressedSavedBytes': a['compressedBytes'] - b['compressedBytes'],
                     'relocationSavedBytes': a['relocations']['bytes'] - b['relocations']['bytes']})
    return rows


def apk_sizes(path, report):
    totals = {}
    with zipfile.ZipFile(path) as archive:
        expected = {name.replace('jni/', 'lib/', 1): library for (_, name), library in libraries(report).items()}
        for name, library in expected.items():
            data = archive.read(name)
            if sha256(data) != library['sha256']:
                raise ValueError(f'{path}/{name}: APK library differs from the measured AAR')
        for info in archive.infolist():
            if info.filename.startswith('lib/') and info.filename.endswith('.so'):
                abi = info.filename.split('/')[1]
                values = totals.setdefault(abi, {'nativeBytes': 0, 'zipCompressedNativeBytes': 0})
                values['nativeBytes'] += info.file_size
                values['zipCompressedNativeBytes'] += info.compress_size
    return {'fileBytes': path.stat().st_size, 'abis': totals}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--before-apk', type=Path)
    parser.add_argument('--after-apk', type=Path)
    args = parser.parse_args()
    if bool(args.before_apk) != bool(args.after_apk):
        parser.error('pass both --before-apk and --after-apk')
    before, after = (json.loads(path.read_text()) for path in (args.before, args.after))
    if after['errors'] or after['baseline']:
        raise SystemExit('candidate report must pass the acceptance gate')
    rows = compare(before, after)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = {'libraries': rows}
    if args.before_apk:
        result['consumerApk'] = {'before': apk_sizes(args.before_apk, before), 'after': apk_sizes(args.after_apk, after)}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    lines = ['| Model | ABI/library | Before bytes | After bytes | Saved bytes | Saved % | AAR compressed saving |',
             '| --- | --- | ---: | ---: | ---: | ---: | ---: |']
    lines += [f"| {r['model']} | {r['library']} | {r['beforeBytes']} | {r['afterBytes']} | {r['savedBytes']} | {r['savedPercent']:.2f} | {r['compressedSavedBytes']} |" for r in rows]
    args.output.with_suffix('.md').write_text('\n'.join(lines) + '\n')
    print(f'Compared {len(rows)} libraries: {args.output}')


if __name__ == '__main__':
    main()
