"""Build a version-bound file overlay from a Telegram IPA and a VeilGram IPA."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import struct
import zipfile

APP = 'Payload/Telegram.app/'
MANIFEST = '.veilgram-patch.json'
TELEGRAM_ID = 'ph.telegra.Telegraph'


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def files(archive):
    result = {}
    for item in archive.infolist():
        if not item.filename.startswith(APP) or item.is_dir():
            continue
        path = item.filename[len(APP):]
        if (any(part in ('', '.', '..') for part in path.split('/')) or
                any(ord(character) < 32 or character in '\\:' for character in path) or
                (item.external_attr >> 16 & 0o170000) == 0o120000 or path in result or path == MANIFEST):
            raise ValueError(f'Unsupported IPA entry: {item.filename}')
        result[path] = item
    return result


def assert_decrypted(archive, executable):
    with archive.open(APP + executable) as stream:
        head = stream.read(32)
        if len(head) != 32 or struct.unpack_from('<II', head) != (0xfeedfacf, 0x0100000c):
            raise ValueError('Expected a thin ARM64 iPhone executable.')
        commands, size = struct.unpack_from('<II', head, 16)
        if size > 16 * 1024 * 1024:
            raise ValueError('Invalid Mach-O load commands.')
        data = stream.read(size)
        position = 0
        for _ in range(commands):
            if position + 8 > len(data):
                raise ValueError('Truncated Mach-O load commands.')
            op, length = struct.unpack_from('<II', data, position)
            if length < 8 or position + length > len(data):
                raise ValueError('Invalid Mach-O load command.')
            if op in (0x21, 0x2c):
                if length < 20 or struct.unpack_from('<I', data, position + 16)[0] != 0:
                    raise ValueError('The Telegram IPA must already be decrypted.')
            position += length


def same_contents(base, old, target, new):
    if old.file_size != new.file_size or old.CRC != new.CRC:
        return False
    with base.open(old) as first, target.open(new) as second:
        for block in iter(lambda: first.read(1024 * 1024), b''):
            if block != second.read(len(block)):
                return False
    return True


def parents(paths):
    return {path[:i] for path in paths for i, character in enumerate(path) if character == '/'}


def build(base_path, target_path, destination, notes=''):
    if base_path.resolve() == target_path.resolve():
        raise ValueError('Provide Telegram and VeilGram as separate IPA files.')
    destination.mkdir(parents=True, exist_ok=True)
    base_output = destination / 'Telegram.ipa'
    if target_path.resolve() == base_output.resolve():
        raise ValueError('The VeilGram IPA must be outside the output path for Telegram.')
    base_sha = digest(base_path)
    patch = destination / 'VeilGram-patch.zip'

    with zipfile.ZipFile(base_path) as base, zipfile.ZipFile(target_path) as target:
        original = plistlib.loads(base.read(APP + 'Info.plist'))
        modified = plistlib.loads(target.read(APP + 'Info.plist'))
        if original.get('CFBundleIdentifier') != TELEGRAM_ID or original.get('CFBundleExecutable') != 'Telegram':
            raise ValueError('The base must be the original Telegram app.')
        if modified.get('CFBundleDisplayName') != 'VeilGram' or modified.get('CFBundleExecutable') != 'Telegram':
            raise ValueError('The target must be a VeilGram build.')
        assert_decrypted(base, 'Telegram')
        assert_decrypted(target, 'Telegram')
        before, after = files(base), files(target)
        absent = (set(before) | parents(before)) - (set(after) | parents(after))
        removed = sorted(path for path in absent if not parents([path]) & absent)
        changed = [path for path, entry in after.items()
                   if path not in before or not same_contents(base, before[path], target, entry)]
        if not changed:
            raise ValueError('Telegram and VeilGram contain the same app files.')
        temporary = patch.with_suffix('.tmp')
        try:
            with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as overlay:
                overlay.writestr(APP + MANIFEST, json.dumps({'format': 1, 'baseSHA256': base_sha, 'remove': removed}))
                for path in sorted(changed):
                    with target.open(after[path]) as source, overlay.open(APP + path, 'w') as output:
                        shutil.copyfileobj(source, output)
            temporary.replace(patch)
        finally:
            temporary.unlink(missing_ok=True)

    def asset(path, sha):
        return {'path': '/patcher/' + path.name, 'size': path.stat().st_size, 'sha256': sha}

    if base_path.resolve() != base_output.resolve():
        temporary = base_output.with_suffix('.tmp')
        try:
            shutil.copyfile(base_path, temporary)
            if digest(temporary) != base_sha:
                raise ValueError('The base IPA changed during packaging.')
            temporary.replace(base_output)
        finally:
            temporary.unlink(missing_ok=True)
    catalog = destination / 'latest.json'
    temporary = catalog.with_suffix('.tmp')
    temporary.write_text(json.dumps({
        'version': str(modified.get('CFBundleShortVersionString') or 'VeilGram'),
        'build': str(modified.get('CFBundleVersion') or ''),
        'telegramVersion': str(original.get('CFBundleShortVersionString') or ''),
        'notes': notes[:2000],
        'base': asset(base_output, base_sha), 'patch': asset(patch, digest(patch))
    }) + '\n', encoding='utf-8')
    temporary.replace(catalog)
    print(f'{len(changed)} changed files, {len(removed)} removals. Catalog: {catalog}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('telegram', type=Path)
    parser.add_argument('veilgram', type=Path)
    parser.add_argument('--output', type=Path, default=Path('out/patcher'))
    parser.add_argument('--notes', default='')
    args = parser.parse_args()
    build(args.telegram, args.veilgram, args.output, args.notes)
