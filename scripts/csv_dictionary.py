#!/usr/bin/env python3
"""Compile SI-maintained category CSV files into the shared read-only SQLite format."""

import argparse
from contextlib import closing
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile

import lexicon_database as lexicon

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'Data/Vocabulary'
RESOURCES = ROOT / 'mac/SI/Core/Resources'
DATABASES = {'chinese': 'si-pinyin.sqlite', 'english': 'si-english.sqlite'}
COLUMNS = ['text', 'reading', 'weight']
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


def metadata():
    raw = (DATA / 'meta.json').read_bytes()
    value = json.loads(raw)
    if value.get('schema_version') != 2 or value.get('dictionary_format') != lexicon.FORMAT:
        raise ValueError('Unsupported CSV metadata or dictionary format')
    if set(value.get('languages', {})) != set(DATABASES):
        raise ValueError('Metadata must describe Chinese and English')
    if value.get('category_overlap', 'maximum') not in ('maximum', 'base'):
        raise ValueError('Unsupported category overlap policy')
    for language, categories in value.get('upstream_categories', {}).items():
        if (language not in DATABASES or not isinstance(categories, list)
                or len(categories) != len(set(categories))
                or any(not re.fullmatch(r'[a-z][a-z0-9_-]*\.csv', name) or name == 'base.csv'
                       or not (DATA / language / name).is_file() for name in categories)):
            raise ValueError('Invalid authoritative upstream categories')
    for language in DATABASES:
        unknown = value['languages'][language].get('unknown_weight')
        if type(unknown) is not int or not 1 <= unknown <= 2**63 - 1:
            raise ValueError('Invalid unknown weight: ' + language)
    upstreams = value.get('upstreams')
    if not isinstance(upstreams, list) or not upstreams:
        raise ValueError('Metadata requires upstream provenance')
    identities = set()
    for upstream in upstreams:
        identity = upstream.get('id')
        if not isinstance(identity, str) or not identity or identity in identities:
            raise ValueError('Upstream IDs must be nonempty and unique')
        identities.add(identity)
        if not isinstance(upstream.get('metadata'), dict) or not upstream['metadata']:
            raise ValueError('Upstream metadata must be a nonempty inline object')
        path = Path(upstream['attribution'])
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Provenance paths must stay inside the repository')
        if digest((ROOT / path).read_bytes()) != upstream['attribution_sha256']:
            raise ValueError('Provenance checksum mismatch: ' + str(path))
    return value, digest(raw)


def integer(value, minimum, field):
    if not re.fullmatch(r'[0-9]+', value) or not minimum <= int(value) <= 2**63 - 1:
        raise ValueError('Invalid ' + field)
    return int(value)


def rows(language):
    directory = DATA / language
    sources = sorted(directory.glob('*.csv'))
    if directory / 'base.csv' not in sources:
        raise ValueError('Missing base.csv: ' + language)
    configuration = json.loads((DATA / 'meta.json').read_bytes())
    upstream = set(configuration.get('upstream_categories', {}).get(language, []))
    records, parsed, base, imported = [], {}, {}, {}
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
                # A blank local weight uses SI's new-entry prior. Imported weights
                # must stay explicit, including upstream zero/missing-weight rows.
                weight = (DEFAULT_NEW_ENTRY_WEIGHT if weight == '' and path.name != 'base.csv'
                          and path.name not in upstream else integer(weight, 0, 'weight'))
                identity = (reading, text)
                # Category overlap must not inflate frequency or choose a file winner.
                parsed[identity] = max(parsed.get(identity, 0), weight)
                if path.name == 'base.csv':
                    base[identity] = max(base.get(identity, 0), weight)
                elif path.name in upstream:
                    imported[identity] = max(imported.get(identity, 0), weight)
                count += 1
            except ValueError as error:
                raise ValueError(f'{path}:{reader.line_num}: {error}') from error
        records.append({'path': f'{language}/{path.name}', 'sha256': digest(content), 'rows': count})
    policy = configuration.get('category_overlap', 'maximum')
    if policy == 'base':
        # A pinned base owns its weights and canonical English casing. Preserved
        # category files add identities, without reviving superseded base weights.
        if language == 'english':
            base_texts = {text.lower() for _, text in base}
            parsed = {identity: weight for identity, weight in parsed.items()
                      if identity[1].lower() not in base_texts}
        parsed.update(imported)
        parsed.update(base)
    # Content alone defines tie order: moving/reordering rows or renaming categories
    # cannot alter the effective dictionary. Preserve exact output bytes.
    identities = sorted(parsed, key=lambda pair: (pair[0].encode('utf-8'), pair[1].encode('utf-8')))
    return [(text, reading, parsed[(reading, text)]) for reading, text in identities], records


def prepare(language, meta, meta_hash):
    entries, sources = rows(language)
    output = RESOURCES / language.title()
    output.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=output, suffix='.sqlite')
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        with closing(sqlite3.connect(temporary)) as connection:
            lexicon.create_schema(connection, meta['languages'][language]['unknown_weight'])
            for index, (text, reading, weight) in enumerate(entries, 1):
                table = lexicon.table_for(reading, allow_domain=language == 'english')
                connection.execute(f'INSERT INTO {table} (rowid,key,jp,value,weight) VALUES (?,?,?,?,?)',
                                   (index, reading, ''.join(s[0] for s in reading.split("'")), text, weight))
            if language == 'english':
                for table in lexicon.TABLES:
                    if connection.execute(f'SELECT lower(value) FROM {table} GROUP BY lower(value) HAVING count(*)>1 LIMIT 1').fetchone():
                        raise ValueError('English outputs must have unique casing; edit the existing casing')
            count = lexicon.finish_schema(connection)
            if count == 0:
                raise ValueError('Dictionary must not be empty: ' + language)
            if connection.execute('PRAGMA integrity_check').fetchone() != ('ok',):
                raise ValueError('Generated dictionary integrity failure')
        manifest = {'schema_version': 2, 'source_format': 'si-category-csv-v2', 'language': language,
                    'dictionary_format': lexicon.FORMAT, 'metadata_sha256': meta_hash,
                    'unknown_weight': meta['languages'][language]['unknown_weight'],
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
    manifest['runtime_sha256'] = actual_hash
    if not manifest_path.exists() or json.loads(manifest_path.read_text()) != manifest:
        raise ValueError('Generated dictionary manifest is out of date; run build')


def build(check=False, language=None):
    meta, meta_hash = metadata()
    prepared = []
    try:
        # Validate and stage every requested language before publishing any output.
        for name in ([language] if language else DATABASES):
            prepared.append(prepare(name, meta, meta_hash))
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
    args = parser.parse_args()
    try:
        build(args.check, args.language)
    except (ValueError, OSError, KeyError, TypeError, UnicodeError, csv.Error, sqlite3.DatabaseError) as error:
        parser.exit(1, f'CSV dictionary error: {error}\n')


if __name__ == '__main__':
    main()
