import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = 'https://github.com/TelegramMessenger/Telegram-iOS.git'
REVISION = '24638bc69bd083981b178dd1e7f921eebbf7fc46'
PROFILE_SOURCES = 'submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources'


def run(*command, cwd=None, check=True, quiet=False):
    return subprocess.run(
        [str(part) for part in command], cwd=cwd, check=check,
        stdout=subprocess.PIPE if quiet else None,
        stderr=subprocess.PIPE if quiet else None, text=True,
    )


def apply(source, patch):
    if run('git', 'apply', '--reverse', '--check', patch, cwd=source, check=False, quiet=True).returncode == 0:
        return
    run('git', 'apply', '--check', patch, cwd=source)
    run('git', 'apply', patch, cwd=source)


def prepare(source):
    if not (source / '.git').exists():
        if source.exists() and any(source.iterdir()):
            raise SystemExit(f'Source directory is not empty: {source}')
        source.mkdir(parents=True, exist_ok=True)
        run('git', 'init', cwd=source)
        run('git', 'remote', 'add', 'origin', UPSTREAM, cwd=source)
    head = run('git', 'rev-parse', '--verify', 'HEAD', cwd=source, check=False, quiet=True)
    if head.returncode:
        origin = run('git', 'remote', 'get-url', 'origin', cwd=source, quiet=True).stdout.strip()
        if origin != UPSTREAM:
            raise SystemExit(f'Expected the Telegram-iOS origin in {source}.')
        run('git', 'fetch', '--depth=1', 'origin', REVISION, cwd=source)
        run('git', 'checkout', '--detach', 'FETCH_HEAD', cwd=source)
    elif head.stdout.strip() != REVISION:
        raise SystemExit(f'Expected Telegram-iOS revision {REVISION} in {source}.')

    apply(source, ROOT / 'patches' / 'telegram-ios.patch')
    run('git', 'diff', '--check', cwd=source)
    for filename in ('PolusProfileService.swift', 'PolusProfileView.swift', 'PolusAvatarFrame.swift', 'PolusGIF.swift',
                     'PolusGifts.swift', 'PolusTelegramExchange.swift', 'PolusDeletedArchiveScreen.swift',
                     'PolusHostedProfiles.swift'):
        shutil.copyfile(ROOT / 'ios' / filename, source / PROFILE_SOURCES / filename)
    shutil.copyfile(ROOT / 'ios' / 'PolusDeletedMessages.swift',
                    source / 'submodules/TelegramCore/Sources/State/Sync/PolusDeletedMessages.swift')
    for filename in ('VeilGramGiftLink.swift', 'VeilGramGiftMessage.swift'):
        shutil.copyfile(ROOT / 'ios' / filename, source / 'submodules/TelegramCore/Sources/State/Sync' / filename)
    shutil.copyfile(ROOT / 'ios' / 'VeilGramGiftBubble.swift',
                    source / 'submodules/TelegramUI/Components/Chat/ChatMessageGiftBubbleContentNode/Sources/VeilGramGiftBubble.swift')
    shutil.copyfile(ROOT / 'ios' / 'VeilGramVisualGiftActions.swift',
                    source / 'submodules/AccountContext/Sources/VeilGramVisualGiftActions.swift')
    shutil.copytree(ROOT / 'ios' / 'branding' / 'VeilGram.icon',
                    source / 'Telegram' / 'Telegram-iOS' / 'VeilGram.icon', dirs_exist_ok=True)
    icon_preview = source / 'Telegram' / 'Telegram-iOS' / 'Icons.xcassets' / 'VeilGramIcon.imageset'
    icon_preview.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'ios' / 'branding' / 'veilgram-preview.png', icon_preview / 'VeilGram.png')
    (icon_preview / 'Contents.json').write_text(json.dumps({
        'images': [{'idiom': 'universal', 'filename': 'VeilGram.png'}],
        'info': {'version': 1, 'author': 'xcode'},
    }), encoding='utf-8')
    hosted_url = os.environ.get('VEILGRAM_HOSTED_URL', '').strip()
    hosted_certificate_hash = os.environ.get('VEILGRAM_CERTIFICATE_SHA256', '').strip().lower()
    if hosted_url and not re.fullmatch(r'https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?', hosted_url):
        raise SystemExit('VEILGRAM_HOSTED_URL must be an HTTPS origin.')
    if hosted_certificate_hash and not re.fullmatch(r'[a-f0-9]{64}', hosted_certificate_hash):
        raise SystemExit('VEILGRAM_CERTIFICATE_SHA256 must be a SHA-256 certificate fingerprint.')
    config = source / PROFILE_SOURCES / 'PolusBuildConfig.swift'
    config.write_text(
        f'enum PolusBuildConfig {{\n'
        f'    static let hostedURL = {json.dumps(hosted_url)}\n'
        f'    static let hostedCertificateHash = {json.dumps(hosted_certificate_hash)}\n'
        f'}}\n', encoding='utf-8',
    )
    print(f'Mod source ready: {source}', flush=True)


def write_configuration(mode):
    api_id = os.environ.get('TELEGRAM_API_ID', '').strip()
    api_hash = os.environ.get('TELEGRAM_API_HASH', '').strip()
    if not re.fullmatch(r'[1-9][0-9]{0,9}', api_id) or int(api_id) > 2147483647 or not re.fullmatch(r'[A-Fa-f0-9]{32}', api_hash):
        raise SystemExit('Set TELEGRAM_API_ID and TELEGRAM_API_HASH from my.telegram.org/apps.')
    team_id = os.environ.get('APPLE_TEAM_ID', '').strip() if mode == 'xcode' else '0000000000'
    if not re.fullmatch(r'[A-Z0-9]{10}', team_id):
        raise SystemExit('Set APPLE_TEAM_ID for the Xcode project.')
    bundle_id = os.environ.get('POLUS_BUNDLE_ID', 'org.polus.messenger').strip()
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', bundle_id):
        raise SystemExit('POLUS_BUNDLE_ID must be a reverse-DNS bundle identifier.')
    config = ROOT / '.build' / 'configuration.json'
    config.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
        json.dump({
            'bundle_id': bundle_id, 'api_id': api_id, 'api_hash': api_hash, 'team_id': team_id,
            'is_internal_build': 'false', 'is_appstore_build': 'false', 'appstore_id': '0',
            'app_specific_url_scheme': 'polus', 'premium_iap_product_id': '',
            'enable_siri': False, 'enable_icloud': False,
        }, handle)
    return config


def native_build(source, mode, config, number):
    dependency_command = ('git', 'submodule', 'update', '--init', '--recursive', '--jobs', '8')
    if run(*dependency_command, '--depth', '1', cwd=source, check=False).returncode:
        run(*dependency_command, cwd=source)

    build_input = source / 'build-input'
    build_input.mkdir(exist_ok=True)
    sideload_rc = build_input / 'polus-sideload.bazelrc'
    make = (sys.executable, 'build-system/Make/Make.py')
    signing = (f'--configurationPath={config}', '--xcodeManagedCodesigning')

    if mode == 'xcode':
        sideload_rc.unlink(missing_ok=True)
        run(*make, f'--cacheDir={ROOT / ".build" / "bazel-cache"}', 'generateProject', *signing, cwd=source)
        return

    apply(source / 'build-system' / 'bazel-rules' / 'rules_apple', ROOT / 'patches' / 'unsigned-ios.patch')
    sideload_rc.write_text(
        'build --//Telegram:disableProvisioningProfiles\n'
        'build --//Telegram:disableExtensions\n'
        'build --features=polus_unsigned_compilation --features=disable_legacy_signing\n', encoding='ascii',
    )
    run(*make, 'build', *signing, f'--buildNumber={number}', '--configuration=release_arm64', cwd=source)

    archive = source / 'bazel-bin' / 'Telegram' / 'Telegram.ipa'
    output = ROOT / 'out' / 'VeilGram-unsigned.ipa'
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as package:
        if 'Payload/Telegram.app/Telegram' not in package.namelist():
            raise SystemExit('The Bazel archive has no iOS executable.')
        if any(name.endswith('/embedded.mobileprovision') for name in package.namelist()):
            raise SystemExit('The sideload archive contains an unexpected provisioning profile.')
    shutil.copyfile(archive, output)
    print(f'IPA ready for signing: {output}')


def main():
    parser = argparse.ArgumentParser(description='Prepare and build the pinned VeilGram iOS client.')
    parser.add_argument('mode', choices=['prepare', 'xcode', 'ipa'])
    parser.add_argument('--source', type=Path, default=ROOT / 'Telegram-iOS')
    parser.add_argument('--build-number', type=int, default=100001)
    args = parser.parse_args()

    config = None
    if args.mode != 'prepare':
        if sys.platform != 'darwin':
            raise SystemExit('iOS compilation requires macOS and Xcode 27.1. Use the macOS GitHub Actions workflow from Windows.')
        config = write_configuration(args.mode)

    source = args.source.resolve()
    prepare(source)
    if config:
        native_build(source, args.mode, config, args.build_number)


if __name__ == '__main__':
    main()
