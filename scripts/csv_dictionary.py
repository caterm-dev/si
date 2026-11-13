#!/usr/bin/env python3
"""Compile SI-maintained category CSV files into the shared read-only SQLite format."""

import argparse
from contextlib import closing
import csv
import hashlib
import io
import json
import math
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import sqlite3
import tempfile

import lexicon_database as lexicon

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'Data'
RESOURCES = ROOT / '.build/legacy-dictionaries'
DATABASES = {'chinese': 'si-pinyin.sqlite', 'english': 'si-english.sqlite'}
COLUMNS = ['text', 'reading', 'weight']
# Retained for legacy category-authoring tools; compilation always requires explicit counts.
DEFAULT_NEW_ENTRY_WEIGHT = 10
DIGIT_READINGS = ('zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine')


def english_reading(text):
    """Literal domain key, or the alphabetic key for ordinary words/titles."""
    if (not text or text != text.strip() or not all(32 <= ord(c) <= 126 for c in text)
            or not re.search(r'[A-Za-z]', text)):
        raise ValueError('English requires printable ASCII text containing letters')
    domain = lexicon.domain_reading(text)
    if domain is not None:
        return domain
    key = ''.join(c.lower() if c.isalpha() else DIGIT_READINGS[int(c)] if c.isdigit() else ''
                  for c in text)
    if not 1 <= len(key) <= 64:
        raise ValueError('English reading must contain 1–64 ASCII letters')
    return key


def digest(content):
    return hashlib.sha256(content).hexdigest()


def write_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.incoming-')
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(content)
        os.replace(temporary, path)
        path.chmod(0o644)
    finally:
        Path(temporary).unlink(missing_ok=True)


def category_sources(language):
    return sorted((DATA / language.title()).glob('*.csv'))


def integer(value, minimum, field):
    if not re.fullmatch(r'[0-9]+', value) or not minimum <= int(value) <= 2**63 - 1:
        raise ValueError('Invalid ' + field)
    return int(value)


def rows(language):
    directory = DATA / language.title()
    sources = category_sources(language)
    if directory / 'base.csv' not in sources:
        raise ValueError('Missing base.csv: ' + language)
    records, parsed = [], {}
    for path in sources:
        if path.is_symlink() or not re.fullmatch(r'[a-z][a-z0-9_-]*\.csv', path.name):
            raise ValueError('Invalid category filename: ' + path.name)
        content = path.read_bytes()
        reader = csv.reader(io.StringIO(content.decode('utf-8-sig'), newline=''), strict=True)
        if next(reader, None) != COLUMNS:
            raise ValueError(f'{path}: expected CSV header {",".join(COLUMNS)}')
        count = 0
        for row in reader:
            try:
                if len(row) != len(COLUMNS):
                    raise ValueError('Expected three CSV fields')
                text, reading, weight = row
                if (not text.strip() or len(text.encode('utf-8')) > 4096
                        or any(ord(c) < 32 or ord(c) == 127 for c in text)):
                    raise ValueError('Invalid dictionary text')
                lexicon.table_for(reading, allow_domain=language == 'english')
                if language == 'english':
                    if reading != english_reading(text):
                        raise ValueError('English reading must match its literal domain or alphabetic word/title key')
                    if path.stem == 'domain' and (lexicon.domain_reading(text) != text or reading != text):
                        raise ValueError('Domain rows require a full lowercase domain and identical reading')
                elif reading[0] not in 'abcdefghjklmnopqrstwxyz':
                    raise ValueError('Unsupported Chinese reading')
                weight = integer(weight, 0, 'count')
                identity = (reading, text)
                parsed[identity] = parsed.get(identity, 0) + weight
                if parsed[identity] > 2**63 - 1:
                    raise ValueError('Merged count exceeds signed 64-bit limit')
                count += 1
            except ValueError as error:
                raise ValueError(f'{path}:{reader.line_num}: {error}') from error
        records.append({'path': path.relative_to(DATA).as_posix(), 'sha256': digest(content), 'rows': count})
    # Content alone defines tie order: moving/reordering rows or renaming categories
    # cannot alter the effective dictionary. Preserve exact output bytes.
    identities = sorted(parsed, key=lambda pair: (pair[0].encode('utf-8'), pair[1].encode('utf-8')))
    return [(text, reading, parsed[(reading, text)]) for reading, text in identities], records


def prepare(language, corpus_version=None):
    entries, sources = rows(language)
    total_n = sum(weight for _, _, weight in entries)
    if not 0 < total_n <= 2**63 - 1:
        raise ValueError('Total count must be positive and fit a signed 64-bit integer: ' + language)
    log_total = math.log10(total_n)
    corpus_hash = digest(json.dumps(entries, ensure_ascii=False, separators=(',', ':')).encode())
    metadata = {**lexicon.FORMAT, 'total_n': total_n, 'log_base': 'log10',
                'corpus_version': corpus_version or ('sha256:' + corpus_hash),
                'built_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
                'unk_logp': math.log10(0.5) - log_total}
    output = RESOURCES / language.title()
    output.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=output, suffix='.sqlite')
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        with closing(sqlite3.connect(temporary)) as connection:
            lexicon.create_schema(connection, metadata)
            for index, (text, reading, weight) in enumerate(entries, 1):
                table = lexicon.table_for(reading, allow_domain=language == 'english')
                connection.execute(f'INSERT INTO {table} (rowid,key,jp,value,weight) VALUES (?,?,?,?,?)',
                                   (index, reading, ''.join(s[0] for s in reading.split("'")), text,
                                    math.log10(weight) - log_total if weight else metadata["unk_logp"]))
            count = lexicon.finish_schema(connection)
            if count == 0:
                raise ValueError('Dictionary must not be empty: ' + language)
            if connection.execute('PRAGMA integrity_check').fetchone() != ('ok',):
                raise ValueError('Generated dictionary integrity failure')
        manifest = {'schema_version': 3, 'source_format': 'si-count-csv-v3', 'language': language,
                    'dictionary_format': lexicon.FORMAT, 'meta': metadata,
                    'sources': sources, 'entries': count, 'runtime_sha256': digest(temporary.read_bytes())}
        return temporary, output / DATABASES[language], output / 'dictionary-manifest.json', manifest
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def check_prepared(temporary, target, manifest_path, manifest):
    if not target.exists():
        raise ValueError('Generated dictionary is out of date; run build')
    actual_hash = digest(target.read_bytes())
    if actual_hash != manifest['runtime_sha256'] and not lexicon.same_dictionary(temporary, target):
        raise ValueError('Generated dictionary is out of date; run build')
    with closing(sqlite3.connect(target.resolve().as_uri() + '?mode=ro&immutable=1', uri=True)) as connection:
        manifest['meta']['built_at'] = connection.execute("SELECT value FROM meta WHERE key='built_at'").fetchone()[0]
    manifest['runtime_sha256'] = actual_hash
    if not manifest_path.exists() or json.loads(manifest_path.read_text()) != manifest:
        raise ValueError('Generated dictionary manifest is out of date; run build')


def build(check=False, language=None, corpus_version=None):
    if corpus_version is not None and not corpus_version.strip():
        raise ValueError('Corpus version must not be empty')
    prepared = []
    try:
        # Validate and stage every requested language before publishing any output.
        for name in ([language] if language else DATABASES):
            prepared.append(prepare(name, corpus_version))
        for temporary, target, manifest_path, manifest in prepared:
            if check:
                check_prepared(temporary, target, manifest_path, manifest)
            else:
                os.replace(temporary, target)
                target.chmod(0o644)
                write_atomic(manifest_path, (json.dumps(manifest, indent=2) + '\n').encode())
            print(f'{"Checked" if check else "Wrote"} SI {manifest["language"]} dictionary: {manifest["entries"]} entries')
    finally:
        for temporary, *_ in prepared:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    command = sub.add_parser('build', help='Compile all category CSV files offline')
    command.add_argument('--check', action='store_true', help='Verify without replacing outputs')
    command.add_argument('--language', choices=DATABASES)
    command.add_argument('--corpus-version', help='Explicit snapshot version; defaults to SHA-256 of effective counts')
    args = parser.parse_args()
    try:
        build(args.check, args.language, args.corpus_version)
    except (ValueError, OSError, KeyError, TypeError, UnicodeError, csv.Error, sqlite3.DatabaseError) as error:
        parser.exit(1, f'CSV dictionary error: {error}\n')


if __name__ == '__main__':
    main()
