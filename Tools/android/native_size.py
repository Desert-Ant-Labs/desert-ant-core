"""Account for Android ELF relocations and retained LLD input sections."""
import hashlib
import json
from pathlib import Path
import re
import struct


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def is_prebuilt_runtime(model, name):
    return model == 'core' or (model == 'title' and Path(name).name == 'liblitert-lm.so')


def relocations(data):
    # Both shipping ABIs are ELF64 little-endian. Reject malformed metadata
    # rather than reporting an empty table as a successful packing check.
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('expected a little-endian ELF64 library')
    offset = struct.unpack_from('<Q', data, 40)[0]
    stride, count, strings_index = struct.unpack_from('<HHH', data, 58)
    if stride != 64 or not count or strings_index >= count or offset + stride * count > len(data):
        raise ValueError('invalid ELF section table')
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * stride) for i in range(count)]
    def payload(section):
        start, size = section[4:6]
        if start + size > len(data):
            raise ValueError('ELF section extends beyond the file')
        return data[start:start + size]
    strings = payload(sections[strings_index])
    tables, tags = {}, {}
    for section in sections:
        name_offset = section[0]
        end = strings.find(b'\0', name_offset)
        if name_offset >= len(strings) or end < 0:
            raise ValueError('invalid ELF section name')
        name = strings[name_offset:end].decode('ascii')
        if section[1] == 6:  # SHT_DYNAMIC
            dynamic = payload(section)
            if len(dynamic) % 16:
                raise ValueError('invalid ELF dynamic table')
            tags.update(struct.iter_unpack('<qQ', dynamic))
        if section[1] in (4, 9, 19, 0x60000001, 0x60000002, 0x6fffff00):
            tables[name] = {'bytes': section[5], 'type': section[1], 'address': section[3]}
            if section[1] in (0x60000001, 0x60000002):
                tables[name]['aps2'] = payload(section).startswith(b'APS2')
    problems = []
    packed = [table for table in tables.values() if table['type'] in (0x60000001, 0x60000002)]
    for table in packed:
        address_tag, size_tag = (0x6000000f, 0x60000010) if table['type'] == 0x60000001 else (0x60000011, 0x60000012)
        if not table['aps2'] or table['bytes'] <= 4 or tags.get(address_tag) != table['address'] or tags.get(size_tag) != table['bytes']:
            problems.append('invalid Android packed relocation payload or dynamic tags')
    if not packed:
        problems.append('missing Android packed relocations')
    if any(t['type'] in (19, 0x6fffff00) for t in tables.values()) or any(tag in tags for tag in (35, 36, 37, 0x6fffe000, 0x6fffe001, 0x6fffe003)):
        problems.append('RELR relocations require a newer Android API')
    if tags.get(8, 0) or tags.get(18, 0):  # DT_RELASZ / DT_RELSZ, excluding PLT
        problems.append('unpacked dynamic relocations')
    return {'sections': tables, 'bytes': sum(t['bytes'] for t in tables.values()),
            'packedBytes': sum(t['bytes'] for t in packed), 'problems': problems}


def link_map(text):
    if not re.search(r'VMA\s+LMA\s+Size\s+Align\s+Out\s+In\s+Symbol', text):
        raise ValueError('unrecognized LLD map header')
    archives, modules, generated = {}, {}, 0
    output = ''
    for line in text.splitlines():
        columns = line.split(None, 4)
        if len(columns) != 5:
            continue
        source = columns[4].strip()
        if source.startswith('.') and not any(char.isspace() for char in source):
            output = source
        # Non-file-backed and non-allocated sections do not explain install size.
        if output.startswith(('.debug', '.zdebug')) or output in ('.bss', '.tbss', '.symtab', '.strtab', '.shstrtab', '.comment'):
            continue
        source, separator, section = source.rpartition(':(')
        if not separator or not section.endswith(')'):
            continue
        archive = re.search(r'([^/\\]+\.a)\([^()]+\)$', source) if '.a(' in source else None
        if not archive and not source.endswith('.o') and source != '<internal>':
            continue
        size = int(columns[2], 16)
        if source == '<internal>':
            generated += size
            continue
        if archive:
            name = re.sub(r'libclang_rt\.builtins-(?:aarch64|x86_64)-android', 'libclang_rt.builtins-android', archive[1])
            archives[name] = archives.get(name, 0) + size
        else:
            module = re.search(r'/([^/]+?)(?:-t)?\.build/', source)
            name = module[1] if module else Path(source).stem
            modules[name] = modules.get(name, 0) + size
    if not archives or not modules:
        raise ValueError('LLD map has no archive or module contributions')
    return {'archives': dict(sorted(archives.items())), 'modules': dict(sorted(modules.items())),
            'linkerGeneratedBytes': generated}


def attribution(directory, data, allowed):
    metadata = json.loads((directory / 'build.json').read_text())
    map_data = (directory / 'link.map').read_bytes()
    if metadata['librarySha256'] != sha256(data) or metadata['mapSha256'] != sha256(map_data):
        raise ValueError('native report does not match the packaged library and map')
    result = link_map(map_data.decode())
    result['build'] = metadata
    result['problems'] = [f'unreviewed runtime archive: {name}' for name in result['archives'] if name not in allowed]
    return result


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('library', type=Path)
    parser.add_argument('--swift', required=True)
    parser.add_argument('--ndk', required=True)
    parser.add_argument('--api', required=True)
    parser.add_argument('--litert', required=True)
    args = parser.parse_args()
    (args.directory / 'build.json').write_text(json.dumps({
        'librarySha256': sha256(args.library.read_bytes()),
        'mapSha256': sha256((args.directory / 'link.map').read_bytes()),
        'swift': args.swift, 'ndk': args.ndk, 'api': args.api, 'litert': args.litert,
    }, indent=2) + '\n')
