#!/usr/bin/env python3
"""Check a synthetic QA backup without printing payloads or passwords. Never use a real backup."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import subprocess
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def inspect(profile, image):
    root = Path('/private/tmp/akb-qa-' + str(profile).upper())
    require(root.is_dir() and not root.is_symlink(), 'QA profile is not running')
    image = image.resolve()
    require(image.is_relative_to(root) and image.suffix == '.dmg', 'Backup must be inside this QA profile')
    config = json.loads((root / 'submission-fixture.json').read_text())
    require(config['profileID'] == str(profile).upper(), 'Wrong fixture')
    # Deliberately public synthetic-fixture password, never an account or production password.
    # Match BackupArchive.hdiutil: close stdin after the exact password bytes.
    # hdiutil treats a trailing newline as part of the password.
    password = b'akb-synthetic-backup-42!'
    raw = image.read_bytes()
    values = ['4242424242424242', 'AKB synthetic card fixture'] + [f'fixture-submit-code-{n:03}' for n in range(1, 9)]
    require(all(value.encode() not in raw for value in values), 'Plain synthetic value in encrypted image')
    info = subprocess.run(['hdiutil', 'imageinfo', '-plist', '-stdinpass', str(image)], input=password,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    metadata = plistlib.loads(info.stdout)
    require(metadata.get('Format') == 'UDZO' and metadata.get('Properties', {}).get('Encrypted') is True,
            'Expected compressed encrypted image')
    mount = root / 'backup-inspection'
    mount.mkdir(mode=0o700)
    attached = False
    try:
        subprocess.run(['hdiutil', 'attach', '-quiet', '-readonly', '-stdinpass', '-nobrowse', '-noautoopen',
                        '-mountpoint', str(mount), str(image)], input=password,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        attached = True
        data = json.loads((mount / '.agentkeybox-backup.json').read_text())
        require(data['format'] == 'agentkeybox-backup' and data['version'] == 2, 'Not a typed backup')
        contents = data['contents']
        stored = json.loads((root / 'metadata.json').read_text())
        require(contents['credentials'] == stored['credentials'] and contents['projects'] == stored['projects'],
                'Backup metadata differs from current native items')
        require(len(contents['credentials']) == 2, 'Only the two synthetic fixture items may be inspected')
        statuses = None
        for item in contents['credentials']:
            payload = json.loads(base64.b64decode(contents['secrets'][item['id']]))
            require(payload['revision'] == item['payloadRevision'], 'Backup revision mismatch')
            if item['kind'] == 'creditCard':
                require(payload['card'] == {'number': values[0], 'cardholder': values[1],
                                          'expirationMonth': 12, 'expirationYear': 2099}, 'Unexpected card')
            elif item['kind'] == 'recoveryCodes':
                entries = payload['recoveryCodes']['entries']
                require([entry['value'] for entry in entries] == values[2:], 'Unexpected code values')
                statuses = [entry['status'] for entry in entries]
            else:
                raise RuntimeError('Unexpected backup kind')
        require(statuses == json.loads((root / 'submission-statuses.json').read_text()), 'Backup lost native statuses')
        files = [p for p in mount.rglob('*') if p.is_file()]
        require(not any(p.name in ('.env', 'env.txt') for p in files), 'Protected values entered environment export')
        require(len([p for p in files if p.name.endswith('.card.json')]) == 1
                and len([p for p in files if p.name.endswith('.recovery-codes.json')]) == 1,
                'Missing protected export envelopes')
        print('PASS: encrypted format-2 image; exact synthetic payloads/revisions/statuses; protected JSON only, no env export.')
        print('Code statuses: ' + ', '.join(statuses))
    finally:
        if attached:
            result = subprocess.run(['hdiutil', 'detach', '-quiet', str(mount)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode:
                subprocess.run(['hdiutil', 'detach', '-quiet', '-force', str(mount)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        mount.rmdir()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', type=uuid.UUID)
    parser.add_argument('image', type=Path)
    args = parser.parse_args()
    try:
        inspect(args.profile, args.image)
    except RuntimeError as error:
        raise SystemExit('FAIL: ' + str(error)) from None
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit('FAIL: ' + type(error).__name__ + ': synthetic backup inspection incomplete.') from None
