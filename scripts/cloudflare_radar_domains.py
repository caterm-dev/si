#!/usr/bin/env python3
"""Fetch Cloudflare Radar's unordered top-1000 bucket and merge literal domain CSV rows."""

import argparse
from datetime import datetime, timezone
import csv
import io
import json
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.request

import csv_dictionary as dictionary
import lexicon_database as lexicon

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = 'https://api.cloudflare.com/client/v4/radar/datasets/ranking_top_1000'
SOURCE_DIR = Path('Data/Vocabulary/CloudflareRadar')
SNAPSHOT = SOURCE_DIR / 'top-1000.csv'
SEED = SOURCE_DIR / 'si-authored.csv'
CATEGORY = Path('Data/Vocabulary/english/domain.csv')
METADATA = Path('Data/Vocabulary/meta.json')
NOTICE = Path('mac/SI/Core/Resources/English/CloudflareRadar-NOTICE.txt')
LICENSE = Path('mac/SI/Core/Resources/English/CloudflareRadar-CC-BY-NC-4.0.txt')
TOKEN_KEYS = ('CLOUDFLARE_RADAR_API_TOKEN', 'CLOUDFLARE_API_TOKEN')
MAX_BYTES = 2 * 1024 * 1024


class ImportError(ValueError):
    """A diagnostic safe to display without credentials or remote response bodies."""


def read_token(env_file):
    for key in TOKEN_KEYS:
        if os.environ.get(key):
            return os.environ[key].strip()
    if env_file.is_file():
        for line in env_file.read_text(encoding='utf-8').splitlines():
            key, separator, value = line.strip().removeprefix('export ').partition('=')
            if separator and key.strip() in TOKEN_KEYS:
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                if value:
                    return value
    raise ImportError('Set CLOUDFLARE_RADAR_API_TOKEN in the environment or the ignored .env file.')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        # Never forward the bearer token to a different endpoint or host.
        raise ImportError('Radar returned a redirect; no credential was forwarded.')


def fetch(token):
    if not token or any(c.isspace() for c in token):
        raise ImportError('The Radar token is empty or contains whitespace.')
    request = urllib.request.Request(ENDPOINT, headers={
        'Authorization': 'Bearer ' + token,
        'Accept': 'text/csv',
        'User-Agent': 'SI-domain-maintenance/1',
    })
    try:
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(request, timeout=45) as response:
            raw = response.read(MAX_BYTES + 1)
            # Only public dataset headers are retained, never request/auth headers.
            headers = {name: response.headers[name] for name in ('Date', 'ETag', 'Last-Modified')
                       if response.headers.get(name)}
    except urllib.error.HTTPError as error:
        hint = ' Check that the token has Radar Read permission.' if error.code in (401, 403) else ''
        raise ImportError(f'Radar request failed with HTTP {error.code}.{hint}') from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ImportError('Could not download the Radar dataset; check network access and retry.') from None
    if len(raw) > MAX_BYTES:
        raise ImportError('Radar response exceeds the top-1000 size limit.')
    return raw, headers


def parse_snapshot(raw, expected_count=1000):
    try:
        reader = csv.reader(io.StringIO(raw.decode('utf-8-sig'), newline=''), strict=True)
        if next(reader, None) != ['domain']:
            raise ImportError('Radar response must be a CSV with exactly one domain column.')
        domains = []
        for row in reader:
            if len(row) != 1 or lexicon.domain_reading(row[0]) != row[0]:
                raise ImportError('Radar dataset contains an unsupported or malformed domain row.')
            domains.append(row[0])
    except (UnicodeError, csv.Error):
        raise ImportError('Radar response is not valid UTF-8 domain CSV.') from None
    if len(domains) != expected_count or len(set(domains)) != expected_count:
        raise ImportError(f'Expected exactly {expected_count} unique full domains; no files were changed.')
    return domains


def merge_csv(original, domains):
    reader = csv.DictReader(io.StringIO(original.decode('utf-8'), newline=''))
    if reader.fieldnames != dictionary.COLUMNS:
        raise ImportError('Existing domain CSV has an incompatible header.')
    rows = {}
    for row in reader:
        text = row.get('text', '')
        if (set(row) != set(dictionary.COLUMNS) or lexicon.domain_reading(text) != text
                or row['reading'] != text or text in rows):
            raise ImportError('Existing domain CSV contains invalid or duplicate rows.')
        if row['weight'] == '':
            row['weight'] = str(dictionary.DEFAULT_NEW_ENTRY_WEIGHT)
        dictionary.integer(row['weight'], 0, 'existing domain weight')
        rows[text] = row
    count_before = len(rows)
    for domain in domains:
        rows.setdefault(domain, {'text': domain, 'reading': domain,
                                 'weight': str(dictionary.DEFAULT_NEW_ENTRY_WEIGHT)})
    stream = io.StringIO(newline='')
    writer = csv.DictWriter(stream, fieldnames=dictionary.COLUMNS, lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows[key] for key in sorted(rows))
    return stream.getvalue().encode(), len(rows) - count_before, len(rows)


def publish(changes, expected):
    """Stage all writes, reject intervening edits, and roll back on a publish error."""
    staged, replaced = {}, []
    try:
        for path, content in changes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            descriptor, name = tempfile.mkstemp(dir=path.parent, prefix='.incoming-radar-')
            staged[path] = Path(name)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(content)
            staged[path].chmod(0o644)
        for path, original in expected.items():
            if (path.read_bytes() if path.exists() else None) != original:
                raise ImportError('Source files changed during download; retry without overwriting those edits.')
        for path, temporary in staged.items():
            os.replace(temporary, path)
            replaced.append(path)
    except BaseException:
        for path in reversed(replaced):
            original = expected[path]
            if original is None:
                path.unlink(missing_ok=True)
            else:
                dictionary.write_atomic(path, original)
        raise
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)


def update(env_file=None, input_path=None):
    paths = [CATEGORY, METADATA, SNAPSHOT, SEED, NOTICE, LICENSE]
    expected = {ROOT / path: ((ROOT / path).read_bytes() if (ROOT / path).exists() else None) for path in paths}
    original = expected[ROOT / CATEGORY]
    if original is None or expected[ROOT / METADATA] is None:
        raise ImportError('Run against an existing SI domain CSV and metadata document.')
    # Retained attribution and full license must exist before any external data is adopted.
    notice = expected[ROOT / NOTICE]
    license_bytes = expected[ROOT / LICENSE]
    if notice is None or license_bytes is None:
        raise ImportError('The retained Radar attribution and full CC BY-NC license are required.')
    if input_path is None:
        raw, headers = fetch(read_token(env_file or ROOT / '.env'))
    else:
        raw, headers = input_path.read_bytes(), {}
    domains = parse_snapshot(raw)
    merged, added, total = merge_csv(original, domains)
    meta = json.loads(expected[ROOT / METADATA])
    seed = next(record for record in meta['curations'] if record['id'] == 'basic-domains')
    seed_bytes = expected[ROOT / SEED] or original
    seed.update(catalog=str(SEED), catalog_sha256=dictionary.digest(seed_bytes))
    meta['domain_collection'] = {'path': str(CATEGORY), 'entries': total, 'sha256': dictionary.digest(merged)}
    record = {
        'id': 'cloudflare-radar-top-1000', 'language': 'english',
        'description': 'Cloudflare Radar unordered weekly top-1000 domain bucket; explicit offline merge.',
        'attribution': str(NOTICE), 'attribution_sha256': dictionary.digest(notice),
        'metadata': {
            'provider': 'Cloudflare Radar', 'endpoint': ENDPOINT, 'dataset_alias': 'ranking_top_1000',
            'fetched_at_utc': datetime.now(timezone.utc).isoformat(timespec='seconds'),
            'retrieval': 'authenticated-api' if input_path is None else 'offline-snapshot',
            'response_headers': headers, 'snapshot': str(SNAPSHOT),
            'snapshot_sha256': dictionary.digest(raw), 'domains': len(domains), 'ordered': False,
            'license': 'CC-BY-NC-4.0', 'license_url': 'https://creativecommons.org/licenses/by-nc/4.0/',
            'license_file': str(LICENSE), 'license_sha256': dictionary.digest(license_bytes),
            'transformations': 'Require 1000 unique full lowercase ASCII domains; retain literal readings; '
                               'merge by exact domain; preserve all existing explicit weights; '
                               f'new/blank weights are {dictionary.DEFAULT_NEW_ENTRY_WEIGHT}. '
                               'Bucket membership is not a numeric rank or measured word frequency.',
        },
    }
    meta['upstreams'] = [r for r in meta['upstreams'] if r['id'] != record['id']] + [record]
    changes = {ROOT / CATEGORY: merged, ROOT / METADATA: (json.dumps(meta, ensure_ascii=False, indent=2) + '\n').encode(),
               ROOT / SNAPSHOT: raw, ROOT / SEED: seed_bytes}
    publish(changes, expected)
    return {'fetched': len(domains), 'added': added, 'overlap': len(domains) - added,
            'total_domains': total, 'snapshot_sha256': dictionary.digest(raw)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', type=Path, help='Ignored local dotenv file (default: repository .env)')
    parser.add_argument('--input', type=Path, help='Replay a previously captured top-1000 CSV offline; no token used')
    args = parser.parse_args()
    try:
        report = update(args.env_file, args.input)
    except ImportError as error:
        parser.exit(1, 'Radar domain update failed: ' + str(error) + '\n')
    except (ValueError, OSError, KeyError, TypeError):
        # A token can appear in an exception raised by a third-party HTTP layer;
        # never include arbitrary exception text or a remote response in diagnostics.
        parser.exit(1, 'Radar domain update failed. Check token configuration/Radar Read permission, '
                    'network access, the 1000-row CSV format and unchanged source files. No successful merge is claimed.\n')
    print(json.dumps(report, indent=2))
    print('Merged domain CSV. Rebuild with: python3 scripts/csv_dictionary.py build')


if __name__ == '__main__':
    main()
