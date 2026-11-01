#!/usr/bin/env python3
"""Convert pinned Wanxiang bases/categories while preserving existing SI category files."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import csv
import io
import json
from pathlib import Path
import re
import tempfile
import unicodedata
import urllib.request

import csv_dictionary as dictionary

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'Data/Vocabulary'
PROVENANCE = DATA / 'Wanxiang'
LOCK = PROVENANCE / 'upstream.lock.json'
TONES = {'\u0300', '\u0301', '\u0304', '\u030c'}


def serialized(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def load_lock():
    lock = json.loads(LOCK.read_bytes())
    if (lock.get('schema_version') != 1
            or lock.get('repository') != 'https://github.com/amzxyz/rime-wanxiang-data'
            or not re.fullmatch('[0-9a-f]{40}', lock.get('revision', ''))
            or lock.get('license') != 'CC-BY-4.0'
            or lock.get('category_overlap') not in ('base', 'maximum')):
        raise ValueError('Unsupported Wanxiang source lock')
    seen = set()
    for source in lock['files']:
        path = source['path']
        if (path in seen or not re.fullmatch(r'dicts/[a-z]+\.dict\.yaml', path)
                or source['language'] not in ('chinese', 'english')
                or not re.fullmatch(r'[a-z][a-z0-9_-]*', source.get('category', 'base'))
                or not re.fullmatch('[0-9a-f]{64}', source['sha256'])
                or type(source['size']) is not int or not 0 < source['size'] <= 128 * 1024 * 1024):
            raise ValueError('Invalid Wanxiang source record')
        seen.add(path)
    if {source['language'] for source in lock['files']} != {'chinese', 'english'}:
        raise ValueError('Wanxiang source lock requires both languages')
    documents = lock.get('license_documents', [])
    if {document['name'] for document in documents} != {'LICENSE', 'LICENSE-SCOPE.md', 'NOTICE.md'}:
        raise ValueError('Wanxiang source lock requires full license/scope/notice records')
    for document in documents:
        name = document['name']
        if (Path(name).name != name
                or dictionary.digest((PROVENANCE / name).read_bytes()) != document['sha256']):
            raise ValueError('Wanxiang license checksum mismatch: ' + name)
    return lock


def verified_source(directory, source):
    path = directory / source['path']
    content = path.read_bytes()
    if len(content) != source['size'] or dictionary.digest(content) != source['sha256']:
        raise ValueError('Wanxiang source checksum mismatch: ' + source['path'])
    return content


def fetch(directory, lock):
    """An explicit maintenance action; normal conversion and builds are offline."""
    for source in lock['files']:
        target = directory / source['path']
        if target.exists():
            verified_source(directory, source)
            print('Verified cached ' + source['path'])
            continue
        url = lock['repository'].replace('github.com', 'raw.githubusercontent.com')
        url += '/' + lock['revision'] + '/' + source['path']
        print('Downloading ' + source['path'], flush=True)
        size = source['size']

        def part(start):
            end = min(size, start + 2 * 1024 * 1024) - 1
            request = urllib.request.Request(url, headers={
                'User-Agent': 'SI-vocabulary-maintenance', 'Range': f'bytes={start}-{end}'})
            with urllib.request.urlopen(request, timeout=180) as response:
                if response.status != 206:
                    raise ValueError('Source server did not honor the requested byte range')
                content = response.read(end - start + 2)
            if len(content) != end - start + 1:
                raise ValueError('Downloaded Wanxiang range length mismatch: ' + source['path'])
            return content

        with ThreadPoolExecutor(max_workers=4) as workers:
            content = b''.join(workers.map(part, range(0, size, 2 * 1024 * 1024)))
        if len(content) != source['size'] or dictionary.digest(content) != source['sha256']:
            raise ValueError('Downloaded Wanxiang checksum mismatch: ' + source['path'])
        dictionary.write_atomic(target, content)
        print('Fetched ' + source['path'])


def rime_rows(content, path):
    """Read the locked dictionaries' plain TSV body, without executing YAML/code."""
    started = ended = False
    for number, line in enumerate(content.decode('utf-8-sig').splitlines(), 1):
        if not ended:
            if line == '---':
                started = True
            elif line == '...' and started:
                ended = True
            elif started and re.match(r'\s*(columns|use_preset_vocabulary)\s*:', line):
                raise ValueError(f'{path}:{number}: unsupported dictionary header')
            continue
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) not in (2, 3) or not fields[0] or not fields[1]:
            raise ValueError(f'{path}:{number}: expected text, code and optional weight')
        # Missing upstream weights remain zero, distinguishable from supplied weights.
        raw_weight = fields[2] if len(fields) == 3 else '0'
        # The pinned jichu file has 14 integer+N weights and one integer+s
        # weight. Rime's std::stod reads the numeric prefix; record that repair.
        matched = re.fullmatch(r'([0-9]+)([Ns]?)', raw_weight)
        if not matched:
            raise ValueError(f'{path}:{number}: invalid Wanxiang weight')
        weight = dictionary.integer(matched[1], 0, 'Wanxiang weight')
        yield number, fields[0], fields[1], weight, len(fields) == 2, bool(matched[2])
    if not ended:
        raise ValueError('Missing Rime dictionary body: ' + path)


def chinese_reading(code):
    syllables = []
    for syllable in code.split(' '):
        if not syllable:
            raise ValueError('Empty Chinese syllable')
        decomposed = unicodedata.normalize('NFD', syllable.lower())
        # Remove tone marks, but preserve the diaeresis before converting ü to v.
        spelling = unicodedata.normalize('NFC', ''.join(c for c in decomposed if c not in TONES))
        spelling = spelling.replace('ü', 'v')
        if not re.fullmatch('[a-z]+', spelling):
            raise ValueError('Unsupported Chinese syllable: ' + repr(syllable))
        syllables.append(spelling)
    reading = "'".join(syllables)
    dictionary.lexicon.table_for(reading)
    if reading[0] not in 'abcdefghjklmnopqrstwxyz':
        raise ValueError('Unsupported Chinese initial')
    return reading


def csv_content(entries):
    output = io.StringIO(newline='')
    writer = csv.writer(output, lineterminator='\n')
    writer.writerow(dictionary.COLUMNS)
    writer.writerows(sorted(entries, key=lambda row: (row[1].encode(), row[0].encode())))
    return output.getvalue().encode()


def convert_sources(directory, lock):
    collected = {}
    reports = []
    for source in lock['files']:
        content = verified_source(directory, source)
        language = source['language']
        destination = language + '/' + source.get('category', 'base') + '.csv'
        entries = collected.setdefault(destination, {})
        counts = Counter()
        exclusions = []
        for number, text, code, weight, missing_weight, suffixed_weight in rime_rows(content, source['path']):
            counts['source_rows'] += 1
            counts['missing_weight'] += missing_weight
            counts['numeric_weight_suffix'] += suffixed_weight
            if (not text.strip() or len(text.encode()) > 4096
                    or any(ord(c) < 32 or ord(c) == 127 for c in text)):
                raise ValueError(f'{source["path"]}:{number}: invalid output text')
            if any(unicodedata.category(c) == 'Co' for c in text):
                counts['excluded_private_use'] += 1
                exclusions.append({'line': number, 'text': text, 'code': code, 'reason': 'private-use output'})
                continue
            if language == 'chinese':
                reading = chinese_reading(code)
                identity = (text, reading)
            else:
                # SI uses full alphabetic typing keys, not Rime abbreviation codes.
                try:
                    reading = dictionary.english_reading(text)
                except ValueError:
                    counts['excluded_unsupported_english'] += 1
                    exclusions.append({'line': number, 'text': text, 'code': code,
                                       'reason': 'outside SI printable-ASCII/full-key contract'})
                    continue
                counts['converted_english_code'] += reading != code.lower()
                identity = text.lower()
            previous = entries.get(identity)
            if previous is not None:
                counts['merged_duplicate'] += 1
            # Toneless Chinese collisions and English case variants use maximum
            # weight; equal weights retain the pinned source's first spelling.
            if previous is None or weight > previous[2]:
                entries[identity] = (text, reading, weight)
            counts['accepted_rows'] += 1
        reports.append({'path': source['path'], 'language': language, 'destination': destination,
                        **dict(sorted(counts.items())), 'exclusions': exclusions})
    outputs = {path: csv_content(entries.values()) for path, entries in collected.items()}
    if any(not collected.get(language + '/base.csv') for language in ('chinese', 'english')):
        raise ValueError('Both imported base dictionaries must be nonempty')
    return outputs, {'schema_version': 1, 'repository': lock['repository'], 'revision': lock['revision'],
                     'category_overlap': lock['category_overlap'], 'sources': reports,
                     'outputs': {path: {'entries': len(entries), 'sha256': dictionary.digest(outputs[path])}
                                 for path, entries in collected.items()}}


def category_hashes(managed):
    return {str(path.relative_to(DATA)): dictionary.digest(path.read_bytes())
            for language in ('chinese', 'english') for path in sorted((DATA / language).glob('*.csv'))
            if str(path.relative_to(DATA)) not in managed}


def prepare_metadata(lock, report, categories):
    meta = json.loads((DATA / 'meta.json').read_bytes())
    meta['dictionary_format'] = dictionary.lexicon.FORMAT
    for language in ('chinese', 'english'):
        meta['languages'][language]['unknown_weight'] = 1
        meta['languages'][language]['base'] = {
            'upstream': 'wanxiang-data', **report['outputs'][language + '/base.csv'],
            'description': 'Pinned Wanxiang source weights, without frequency rescaling.'}
    notice = 'mac/SI/Core/Resources/English/Wanxiang-NOTICE.txt'
    record = {'id': 'wanxiang-data', 'language': 'chinese-and-english',
              'description': 'Current base dictionaries; earlier bootstrap records remain historical attribution.',
              'metadata': {'repository': lock['repository'], 'revision': lock['revision'],
                           'license': 'CC-BY-4.0', 'files': lock['files'],
                           'category_overlap': lock['category_overlap'],
                           'generated_outputs': report['outputs'],
                           'transformations': 'Tone removal; ü to v; SI English full-text keys; maximum duplicate weight; '
                                              'first source spelling on equal-weight case variants; missing weights zero; numeric N/s suffix prefixes; '
                                              'exclude private-use outputs and unsupported English forms.',
                           'preserved_categories': categories},
              'attribution': notice, 'attribution_sha256': dictionary.digest((ROOT / notice).read_bytes())}
    meta['upstreams'] = [r for r in meta['upstreams'] if r['id'] != record['id']] + [record]
    meta['category_overlap'] = lock['category_overlap']
    meta['upstream_categories'] = {language: sorted(Path(path).name for path in report['outputs']
                                                   if path.startswith(language + '/')
                                                   and not path.endswith('/base.csv'))
                                   for language in ('chinese', 'english')}
    return serialized(meta)


def convert(directory, lock, check=False):
    managed = {source['language'] + '/' + source.get('category', 'base') + '.csv' for source in lock['files']}
    previous_meta = json.loads((DATA / 'meta.json').read_bytes())
    previous = next((record['metadata'].get('generated_outputs', {})
                     for record in previous_meta.get('upstreams', []) if record['id'] == 'wanxiang-data'), {})
    retired = set(previous) - managed
    for path in retired:
        if (not re.fullmatch(r'(chinese|english)/[a-z][a-z0-9_-]*\.csv', path)
                or path.endswith('/base.csv')):
            raise ValueError('Invalid retired Wanxiang category: ' + path)
        target = DATA / path
        if target.exists() and dictionary.digest(target.read_bytes()) != previous[path]['sha256']:
            raise ValueError('Retired Wanxiang category has local edits: ' + path)
    before = category_hashes(managed | retired)
    outputs, report = convert_sources(directory, lock)
    report['preserved_categories'] = before
    replacements = {DATA / path: content for path, content in outputs.items()}
    replacements.update({DATA / path: None for path in retired})
    replacements[PROVENANCE / 'conversion-report.json'] = serialized(report)
    replacements[DATA / 'meta.json'] = prepare_metadata(lock, report, before)
    # Validate the complete CSV collection, including unchanged category collisions,
    # before replacing either base. No network or runtime database writes here.
    with tempfile.TemporaryDirectory(prefix='si-wanxiang-validation-') as temporary:
        staging = Path(temporary)
        for language in ('chinese', 'english'):
            (staging / language).mkdir()
            for path in (DATA / language).glob('*.csv'):
                if str(path.relative_to(DATA)) not in managed | retired:
                    (staging / language / path.name).write_bytes(path.read_bytes())
        for path, content in outputs.items():
            (staging / path).write_bytes(content)
        (staging / 'meta.json').write_bytes(replacements[DATA / 'meta.json'])
        original = dictionary.DATA
        try:
            dictionary.DATA = staging
            for language in ('chinese', 'english'):
                entries, _ = dictionary.rows(language)
                if language == 'english' and len({text.lower() for text, _, _ in entries}) != len(entries):
                    raise ValueError('English casing conflict in preserved categories')
        finally:
            dictionary.DATA = original
    if category_hashes(managed | retired) != before:
        raise ValueError('Categories changed during conversion; no bases were replaced')
    if check:
        for path, content in replacements.items():
            if (content is None and path.exists()
                    or content is not None and (not path.exists() or path.read_bytes() != content)):
                raise ValueError('Wanxiang conversion is out of date: ' + str(path.relative_to(ROOT)))
    else:
        # Retain all destination bytes and restore them if any publication step fails.
        old = {path: path.read_bytes() if path.exists() else None for path in replacements}
        try:
            for path, content in replacements.items():
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    dictionary.write_atomic(path, content)
        except BaseException:
            # A write can replace its target before a later chmod/fs operation fails.
            for path in reversed(replacements):
                if old[path] is None:
                    path.unlink(missing_ok=True)
                else:
                    dictionary.write_atomic(path, old[path])
            raise
    for path, details in report['outputs'].items():
        print(f'{"Checked" if check else "Converted"} Wanxiang {path}: {details["entries"]} entries')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('fetch', 'convert'):
        command = sub.add_parser(name)
        command.add_argument('--source-dir', type=Path, help='Directory containing locked dicts/ source files')
        if name == 'convert':
            command.add_argument('--check', action='store_true', help='Check conversion without writing files')
    args = parser.parse_args()
    try:
        lock = load_lock()
        directory = args.source_dir or ROOT / '.build/vocabulary/wanxiang' / lock['revision']
        if args.command == 'fetch':
            fetch(directory, lock)
        else:
            convert(directory, lock, args.check)
    except (ValueError, OSError, KeyError, TypeError, UnicodeError, csv.Error) as error:
        parser.exit(1, f'Wanxiang conversion error: {error}\n')


if __name__ == '__main__':
    main()
