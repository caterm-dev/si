"""Resolve and acquire the latest complete official Chinese Wikipedia text dump."""

import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import os
import tempfile
import time
import urllib.error
import urllib.request

if __package__:
    from .common import CHINESE, LOCK, digest, write_json
else:
    from common import CHINESE, LOCK, digest, write_json

BASE = 'https://dumps.wikimedia.org'
INDEX = BASE + '/zhwiki/'
USER_AGENT = 'SI-corpus-preparation (offline Chinese corpus; public Wikimedia dumps)'


def request(url, **kwargs):
    return urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': USER_AGENT}, **kwargs),
                                  timeout=180)


def resolve_latest():
    with request(INDEX) as response:
        dates = sorted(set(re.findall(r'href="(\d{8})/"', response.read().decode())), reverse=True)
    for date in dates:
        status_url = INDEX + date + '/dumpstatus.json'
        with request(status_url) as response:
            status_bytes = response.read()
        status = json.loads(status_bytes)
        jobs = status.get('jobs', {})
        combined = jobs.get('articlesdumprecombine', {})
        if jobs.get('articlesdump', {}).get('status') != 'done' or combined.get('status') != 'done':
            continue
        filename = f'zhwiki-{date}-pages-articles.xml.bz2'
        checksum_url = INDEX + date + f'/zhwiki-{date}-sha1sums.txt'
        with request(checksum_url) as response:
            checksum_bytes = response.read()
        checksums = {line.split()[1].lstrip('*'): line.split()[0]
                     for line in checksum_bytes.decode().splitlines() if len(line.split()) == 2}
        expected = checksums.get(filename)
        if not expected or not re.fullmatch('[0-9a-f]{40}', expected):
            raise ValueError('Completed Wikipedia dump has no authoritative SHA-1')
        file_record = combined.get('files', {}).get(filename, {})
        if file_record.get('sha1') != expected:
            raise ValueError('Wikipedia completion metadata and checksum manifest disagree')
        url = INDEX + date + '/' + filename
        with request(url, method='HEAD') as response:
            size = int(response.headers['Content-Length'])
        if size != file_record.get('size'):
            raise ValueError('Wikipedia file size differs from completion metadata')
        metadata_root = CHINESE / 'metadata' / 'wikipedia' / date
        metadata_root.mkdir(parents=True, exist_ok=True)
        metadata = []
        for name, content, origin in [('dumpstatus.json', status_bytes, status_url),
                                      ('sha1sums.txt', checksum_bytes, checksum_url)]:
            path = metadata_root / name
            path.write_bytes(content)
            metadata.append({'path': str(path.relative_to(CHINESE)), 'sha256': digest(path), 'url': origin})
        license_documents = []
        for name, origin in [
                ('wikipedia-LICENSE.txt', 'https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt'),
                ('wikipedia-DUMP_TERMS.html', BASE + '/legal.html')]:
            path = CHINESE / 'licenses' / name
            with request(origin) as response:
                path.write_bytes(response.read())
            license_documents.append({'path': str(path.relative_to(CHINESE)), 'sha256': digest(path), 'url': origin})
        source = {
            'id': 'wikipedia', 'name': 'Chinese Wikipedia current article text', 'kind': 'wikipedia',
            'repository': INDEX, 'revision': date, 'path': filename, 'url': url, 'size': size,
            'sha1': expected, 'license': 'CC-BY-SA-4.0', 'share_alike': True,
            'license_document': license_documents[0], 'additional_documents': license_documents[1:] + metadata,
            'scope': 'Complete pages-articles current-revision dump; cleaning selects namespace 0, excludes redirects.',
        }
        print(f'Latest complete Wikipedia: {date}, {size:,} bytes, SHA-1 {expected}', flush=True)
        return source
    raise ValueError('No complete Chinese Wikipedia article dump found')


def verify(path, source):
    if path.stat().st_size != source['size']:
        raise ValueError('Wikipedia dump size mismatch')
    hashes = {'sha1': hashlib.sha1(), 'sha256': hashlib.sha256()}
    with path.open('rb') as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            for value in hashes.values():
                value.update(chunk)
    if hashes['sha1'].hexdigest() != source['sha1']:
        raise ValueError('Wikipedia dump differs from the official SHA-1')
    sha256 = hashes['sha256'].hexdigest()
    if source.get('sha256') and source['sha256'] != sha256:
        raise ValueError('Wikipedia dump differs from the pinned SHA-256')
    return sha256


def download_ranges(source, target):
    """Use at most three connections, Wikimedia's documented per-IP ceiling."""
    width = (source['size'] + 2) // 3
    ranges = [(start, min(source['size'], start + width) - 1)
              for start in range(0, source['size'], width)]
    paths = [target.with_name(target.name + f'.range-{index}.part') for index in range(len(ranges))]
    prefix = target.with_suffix(target.suffix + '.part')
    if prefix.exists():
        if paths[0].exists() or prefix.stat().st_size > width:
            raise ValueError('Existing single-stream prefix cannot be moved safely into range cache')
        prefix.rename(paths[0])

    def transfer(index):
        start, end = ranges[index]
        path = paths[index]
        required = end - start + 1
        for attempt in range(1, 4):
            done = path.stat().st_size if path.exists() else 0
            if done > required:
                raise ValueError('Wikipedia range cache exceeds expected size')
            if done == required:
                return
            request_start = start + done
            headers = {'User-Agent': USER_AGENT, 'Range': f'bytes={request_start}-{end}'}
            try:
                req = urllib.request.Request(source.get('download_url', source['url']), headers=headers)
                with urllib.request.urlopen(req, timeout=180) as response:
                    expected = f'bytes {request_start}-{end}/{source["size"]}'
                    if response.status != 206 or response.headers.get('Content-Range') != expected:
                        raise ValueError('Wikipedia server did not honor the exact requested range')
                    progress_at = time.monotonic()
                    with path.open('ab') as out:
                        while chunk := response.read(4 * 1024 * 1024):
                            done += len(chunk)
                            if done > required:
                                raise ValueError('Wikipedia range response exceeds requested size')
                            out.write(chunk)
                            if time.monotonic() - progress_at >= 30:
                                total = sum(part.stat().st_size for part in paths if part.exists())
                                print(f'Wikipedia ranges: {total:,} / {source["size"]:,} bytes '
                                      f'({total / source["size"]:.1%})', flush=True)
                                progress_at = time.monotonic()
                if done == required:
                    return
            except (urllib.error.URLError, ConnectionError, TimeoutError) as error:
                print(f'Wikipedia range {index} attempt {attempt}: {type(error).__name__}', flush=True)
        raise OSError('Incomplete Wikipedia range after three attempts; cache retained')

    with ThreadPoolExecutor(max_workers=3) as workers:
        list(workers.map(transfer, range(len(ranges))))
    assembly = target.with_name(target.name + '.assembling')
    with assembly.open('wb') as out:
        for path in paths:
            with path.open('rb') as handle:
                while chunk := handle.read(4 * 1024 * 1024):
                    out.write(chunk)
    sha256 = verify(assembly, source)
    assembly.replace(target)
    for path in paths:
        path.unlink()
    print('Wikipedia ranges verified against official SHA-1; SHA-256 ' + sha256, flush=True)
    return sha256


def download(source, raw_root):
    target = Path(raw_root) / source['id'] / source['path']
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        return verify(target, source)
    if source['size'] >= 32 * 1024 * 1024:
        return download_ranges(source, target)
    partial = target.with_suffix(target.suffix + '.part')
    for attempt in range(1, 4):
        done = partial.stat().st_size if partial.exists() else 0
        if done > source['size']:
            raise ValueError('Partial Wikipedia archive exceeds expected size')
        if done == source['size']:
            break
        headers = {'User-Agent': USER_AGENT}
        if done:
            headers['Range'] = f'bytes={done}-'
        try:
            req = urllib.request.Request(source.get('download_url', source['url']), headers=headers)
            with urllib.request.urlopen(req, timeout=180) as response:
                if done and response.status != 206:
                    done = 0
                if response.status == 206:
                    expected_range = f'bytes {done}-{source["size"] - 1}/{source["size"]}'
                    if response.headers.get('Content-Range') != expected_range:
                        raise ValueError('Invalid Wikipedia resume byte range')
                progress_at = time.monotonic()
                with partial.open('ab' if done else 'wb') as handle:
                    while chunk := response.read(4 * 1024 * 1024):
                        done += len(chunk)
                        if done > source['size']:
                            raise ValueError('Wikipedia transfer exceeds pinned size')
                        handle.write(chunk)
                        if time.monotonic() - progress_at >= 30:
                            print(f'Wikipedia download: {done:,} / {source["size"]:,} bytes '
                                  f'({done / source["size"]:.1%})', flush=True)
                            progress_at = time.monotonic()
            if done == source['size']:
                break
            print(f'Incomplete Wikipedia transfer on attempt {attempt}; retaining partial', flush=True)
        except (urllib.error.URLError, ConnectionError, TimeoutError) as error:
            print(f'Wikipedia transfer attempt {attempt}: {type(error).__name__}; retaining partial', flush=True)
    sha256 = verify(partial, source)
    partial.replace(target)
    print('Wikipedia download verified against official SHA-1; SHA-256 ' + sha256, flush=True)
    return sha256


def refresh(raw_root, mirror='official'):
    source = resolve_latest()
    mirrors = {
        'your-org': 'https://dumps.wikimedia.your.org/',
        'acc-umu': 'https://ftp.acc.umu.se/mirror/wikimedia.org/dumps/',
    }
    if mirror in mirrors:
        source['download_url'] = source['url'].replace('https://dumps.wikimedia.org/', mirrors[mirror])
    source['sha256'] = download(source, raw_root)
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    lock['sources'] = [item for item in lock['sources'] if item['id'] != 'wikipedia'] + [source]
    descriptor, name = tempfile.mkstemp(prefix='.wikipedia-pin-', dir=LOCK.parent)
    os.close(descriptor)
    temporary = Path(name)
    try:
        write_json(temporary, lock)
        temporary.replace(LOCK)
    finally:
        temporary.unlink(missing_ok=True)
    return source
