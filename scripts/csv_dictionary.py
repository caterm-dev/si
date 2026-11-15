#!/usr/bin/env python3
"""Read and validate the maintained vocabulary CSV files."""

import csv
import hashlib
import io
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'Data'
COLUMNS = ['text', 'reading', 'weight']
DIGIT_READINGS = ('zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine')


def domain_reading(text):
    """Return a literal ASCII domain key, without accepting standalone suffixes."""
    if not isinstance(text, str) or not text.isascii():
        return None
    key = text.lower()
    label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    if len(key) <= 253 and re.fullmatch(label + r'(?:\.' + label + r')*\.[a-z]{2,63}', key):
        return key
    return None


def english_reading(text):
    """Literal domain key, or the alphabetic key for ordinary words/titles."""
    if (not text or text != text.strip() or not all(32 <= ord(c) <= 126 for c in text)
            or not re.search(r'[A-Za-z]', text)):
        raise ValueError('English requires printable ASCII text containing letters')
    domain = domain_reading(text)
    if domain is not None:
        return domain
    key = ''.join(c.lower() if c.isalpha() else DIGIT_READINGS[int(c)] if c.isdigit() else ''
                  for c in text)
    if not 1 <= len(key) <= 64:
        raise ValueError('English reading must contain 1–64 ASCII letters')
    return key


def digest(content):
    return hashlib.sha256(content).hexdigest()


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
                if language == 'english':
                    if reading != english_reading(text):
                        raise ValueError('English reading must match its literal domain or alphabetic word/title key')
                    if path.stem == 'domain' and (domain_reading(text) != text or reading != text):
                        raise ValueError('Domain rows require a full lowercase domain and identical reading')
                elif (not re.fullmatch(r"[a-z]+(?:'[a-z]+)*", reading)
                      or reading[0] not in 'abcdefghjklmnopqrstwxyz'):
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
