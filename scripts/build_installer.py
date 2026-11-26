#!/usr/bin/env python3
import argparse
import concurrent.futures
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urlsplit
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'installer'
WORK = ROOT / '.build' / 'installer'
TARGET = 'arm64-apple-ios16.0'
DEFAULT_PATCH_SERVER = 'https://patch.forsmc.space:26744'
ZSIGN_REVISION = '9299685bab7ef99827e06e5dfda93af747386590'
OPENSSL_TAG = 'openssl-3.5.6'
OPENSSL_REF = '6cd524886330e84557398cf9e16661b3ececa112'


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def git_value(path, *args):
    return subprocess.check_output(['git', '-C', path, *args], text=True).strip()


def checkout(path, url, ref, expected):
    if not (path / '.git').is_dir():
        path.mkdir(parents=True, exist_ok=True)
        run('git', 'init', '-q', path)
    result = subprocess.run(['git', '-C', path, 'rev-parse', '--verify', 'HEAD'],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if result.returncode == 0 and (path / '.pinned-ref').is_file():
        if (path / '.pinned-ref').read_text() == f'{expected}\n{result.stdout.strip()}\n':
            return
    run('git', '-C', path, 'fetch', '--depth', '1', url, ref)
    if git_value(path, 'rev-parse', 'FETCH_HEAD') != expected:
        raise SystemExit(f'Unexpected dependency revision for {url}')
    run('git', '-C', path, 'checkout', '--detach', 'FETCH_HEAD')
    (path / '.pinned-ref').write_text(f'{expected}\n{git_value(path, "rev-parse", "HEAD")}\n')


def build_native(sdk):
    openssl = WORK / OPENSSL_TAG
    checkout(openssl, 'https://github.com/openssl/openssl.git', f'refs/tags/{OPENSSL_TAG}', OPENSSL_REF)
    if not (openssl / '.built-ios').exists() or not (openssl / 'libcrypto.a').exists():
        run('perl', './Configure', 'ios64-xcrun', '-miphoneos-version-min=16.0',
            'no-shared', 'no-tests', 'no-module', 'no-dso', cwd=openssl)
        run('make', '-j', str(min(8, os.cpu_count() or 1)), 'build_libs', cwd=openssl)
        (openssl / '.built-ios').touch()

    zsign = WORK / 'zsign'
    checkout(zsign, 'https://github.com/zhlynn/zsign.git', ZSIGN_REVISION, ZSIGN_REVISION)
    src = zsign / 'src'
    # The upstream diagnostic shells out to macOS csreq. iOS only needs the signing path.
    original = (src / 'signing.cpp').read_text()
    from_line = '#ifndef _WIN32\n\tif (ZFile::IsFileExists("/usr/bin/csreq"))'
    if from_line not in original:
        raise SystemExit('Could not locate the macOS-only zsign diagnostic.')
    portable_signing = WORK / 'signing-ios.cpp'
    portable_signing.write_text(original.replace(from_line, '#if 0\n\tif (ZFile::IsFileExists("/usr/bin/csreq"))'))
    archive = (src / 'common' / 'archive.cpp').read_text()
    signature = 'NULL, 0, 0)) {'
    if archive.count(signature) != 2 or archive.count('zipOpenNewFileInZip3_64(') != 2:
        raise SystemExit('Could not locate zsign ZIP creation calls.')
    # Preserve UNIX modes in the signed IPA and reject corrupt entries during extraction.
    archive = archive.replace('if (0 == stat(path, &st)) {',
                              'if (0 == stat(path, &st)) {\n\t\tzi->external_fa = (uLong)(st.st_mode & 0xffff) << 16;')
    archive = archive.replace('zipOpenNewFileInZip3_64(', 'zipOpenNewFileInZip4_64(')
    archive = archive.replace(signature, 'NULL, 0, (3U << 8) | 20U, 1U << 11, 0)) {')
    archive = archive.replace('zipClose(zf, NULL);\n\treturn bRet;',
                              'return zipClose(zf, NULL) == ZIP_OK && bRet;')
    archive = archive.replace('fclose(fp);\n\tunzCloseCurrentFile(hZip);\n\treturn bRet;',
                              'fclose(fp);\n\treturn unzCloseCurrentFile(hZip) == UNZ_OK && bRet;')
    portable_archive = WORK / 'archive-ios.cpp'
    portable_archive.write_text(archive)
    cpp_sources = [path for path in sorted(src.glob('*.cpp')) if path.name not in {
        'signing.cpp', 'zsign.cpp', 'certcheck.cpp'
    }]
    cpp_sources += [path for path in sorted((src / 'common').glob('*.cpp')) if path.name != 'archive.cpp']
    cpp_sources += [portable_signing, portable_archive, SOURCE / 'Signer.cpp']
    minizip = src / 'third-party' / 'minizip'
    c_sources = [minizip / f'{name}.c' for name in ('ioapi', 'unzip', 'zip')]
    objects = WORK / 'objects'
    objects.mkdir(exist_ok=True)
    include = ['-I', src, '-I', src / 'common', '-I', openssl / 'include']

    def compile(source):
        output = objects / f'{source.stem}.o'
        cxx = source.suffix == '.cpp'
        flags = ['-std=c++11'] if cxx else []
        run('xcrun', '--sdk', 'iphoneos', 'clang++' if cxx else 'clang',
            '-target', TARGET, '-isysroot', sdk, '-O2', *flags, *include, '-c', source, '-o', output)
        return output

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        compiled = list(pool.map(compile, cpp_sources + c_sources))
    return [*compiled, openssl / 'libcrypto.a']


def manifest_url():
    value = os.environ.get('VEILGRAM_INSTALL_MANIFEST_URL', '').strip()
    if not value:
        base = os.environ.get('VEILGRAM_HOSTED_URL', '').strip().rstrip('/')
        value = f'{base}/install/manifest.plist' if base else DEFAULT_PATCH_SERVER
    parts = urlsplit(value)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise SystemExit('Set VEILGRAM_INSTALL_MANIFEST_URL to an HTTPS URL without credentials or query parameters.')
    return value


def build(number):
    url = manifest_url()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    native = build_native(sdk)
    package = WORK / 'package'
    app = package / 'Payload' / 'VeilGramInstaller.app'
    if package.exists():
        shutil.rmtree(package)
    app.mkdir(parents=True)
    run('xcrun', '--sdk', 'iphoneos', 'swiftc', '-sdk', sdk, '-target', TARGET,
        '-swift-version', '5', '-O', '-parse-as-library', '-module-name', 'VeilGramInstaller',
        '-import-objc-header', SOURCE / 'Signer.h', *sorted(SOURCE.glob('*.swift')),
        *native, '-lc++', '-lz', '-o', app / 'VeilGramInstaller')

    icon = ROOT / 'ios' / 'branding' / 'veilgram-preview.png'
    shutil.copyfile(icon, app / 'VeilGramBrand.png')
    for pixels, suffix in ((120, '@2x'), (180, '@3x')):
        run('sips', '-z', str(pixels), str(pixels), icon, '--out', app / f'AppIcon60x60{suffix}.png')
    info = {
        'CFBundleDevelopmentRegion': 'ru',
        'CFBundleDisplayName': 'VeilGram Patcher',
        'CFBundleExecutable': 'VeilGramInstaller',
        'CFBundleIdentifier': 'org.polus.veilgram.installer',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'VeilGramInstaller',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.0',
        'CFBundleVersion': str(number),
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}},
        'LSRequiresIPhoneOS': True,
        'MinimumOSVersion': '16.0',
        'UIDeviceFamily': [1],
        'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'VeilGramManifestURL': url,
    }
    with (app / 'Info.plist').open('wb') as output:
        plistlib.dump(info, output)
    shutil.copyfile(WORK / 'zsign' / 'LICENSE', app / 'zsign-LICENSE.txt')
    shutil.copyfile(WORK / OPENSSL_TAG / 'LICENSE.txt', app / 'OpenSSL-LICENSE.txt')
    output = ROOT / 'out' / 'VeilGramInstaller-unsigned.ipa'
    output.parent.mkdir(exist_ok=True)
    temporary = output.with_suffix('.ipa.tmp')
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.iterdir()):
            archive.write(path, path.relative_to(package).as_posix())
    temporary.replace(output)
    print(f'Installer ready for signing: {output}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Build the native VeilGram installer for iPhone.')
    parser.add_argument('--build-number', default=1, type=int)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Use macOS with Xcode or the iOS CI workflow.')
    if args.build_number < 1:
        parser.error('The build number must be positive.')
    build(args.build_number)
