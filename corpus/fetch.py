#!/usr/bin/env python3
"""Explicitly download and verify the pinned Chinese corpus archives."""

import argparse
from pathlib import Path
import subprocess
import urllib.request

from common import CHINESE, load_sources, verified_archive


def fetch(source, raw_root):
    target = Path(raw_root) / source['id'] / source['path']
    if target.exists():
        verified_archive(source, raw_root)
        print('Verified cached ' + source['id'], flush=True)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    print('Fetching ' + source['id'], flush=True)
    if source['kind'] == 'wikipedia':
        from wikipedia import download
        download(source, raw_root)
    elif source['kind'] in ('lccc', 'mc4'):
        repository = source['repository'].removeprefix('https://huggingface.co/datasets/')
        subprocess.run([
            'hf', 'download', repository, source['path'], '--type', 'dataset',
            '--revision', source['revision'], '--local-dir', str(Path(raw_root) / source['id']),
            '--quiet',
        ], check=True)
    else:
        partial = target.with_suffix(target.suffix + '.part')
        request = urllib.request.Request(source['url'], headers={'User-Agent': 'SI-public-corpus-preparation'})
        try:
            with urllib.request.urlopen(request, timeout=180) as response, partial.open('wb') as out:
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > source['size']:
                        raise ValueError('Archive exceeds pinned size: ' + source['id'])
                    out.write(chunk)
            # Check the partial before making it available to offline preparation.
            from common import digest
            if size != source['size'] or digest(partial) != source['sha256']:
                raise ValueError('Downloaded archive checksum mismatch: ' + source['id'])
            partial.replace(target)
        finally:
            partial.unlink(missing_ok=True)
    verified_archive(source, raw_root)
    print('Verified ' + source['id'], flush=True)


def main():
    sources = load_sources()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', choices=sorted({'all', 'wikipedia'} | {source['id'] for source in sources}))
    parser.add_argument('--raw-root', type=Path, default=CHINESE / 'raw')
    parser.add_argument('--check', action='store_true', help='Verify local archives without network access')
    parser.add_argument('--latest', action='store_true', help='Resolve and pin the latest complete Wikipedia dump')
    parser.add_argument('--mirror', choices=['official', 'your-org', 'acc-umu'], default='official',
                        help='Wikipedia --latest only; use a Wikimedia-listed mirror for archive bytes')
    args = parser.parse_args()
    if args.latest:
        if args.source != 'wikipedia' or args.check:
            parser.error('--latest requires source wikipedia and cannot be combined with --check')
        from wikipedia import refresh
        refresh(args.raw_root, args.mirror)
        return
    if args.mirror != 'official':
        parser.error('--mirror requires wikipedia --latest')
    if args.source == 'wikipedia' and not any(source['id'] == 'wikipedia' for source in sources):
        parser.error('Wikipedia is not pinned yet; run wikipedia --latest first')
    for source in sources:
        if args.source not in ('all', source['id']):
            continue
        if args.check:
            verified_archive(source, args.raw_root)
            print('Verified ' + source['id'])
        else:
            fetch(source, args.raw_root)


if __name__ == '__main__':
    main()
