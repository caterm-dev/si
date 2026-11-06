#!/usr/bin/env python3
"""Extract complete local raw text lines without Han-only cutting or deduplication."""

from collections import Counter
import argparse
import gzip
import io
import json
from pathlib import Path
import re
import shutil
import time

if __package__:
    from .common import CHINESE, ROOT, digest, load_sources, new_directory, verified_archive, write_json
    from .prepare import documents
else:
    from common import CHINESE, ROOT, digest, load_sources, new_directory, verified_archive, write_json
    from prepare import documents

SURROGATES = re.compile('[\ud800-\udfff]')
LCCC_TOKEN_SPACES = re.compile(r'(?<=[\u3400-\u9fff，。！？；：、]) +(?=[\u3400-\u9fff，。！？；：、])')


def raw_documents(source, archive, counts):
    if source['kind'] not in ('lccc', 'mc4'):
        for origin, text in documents(source, archive, counts, include_title=True):
            yield origin, text, {}
        return
    with gzip.open(archive, 'rt', encoding='utf-8') as handle:
        for index, line in enumerate(handle, 1):
            counts['records_read'] += 1
            row = json.loads(line)
            if source['kind'] == 'lccc':
                if not isinstance(row, list) or not all(isinstance(turn, str) for turn in row):
                    raise ValueError('Invalid LCCC raw record at row ' + str(index))
                for turn_index, turn in enumerate(row):
                    # Restore this tokenized release without concatenating English
                    # words or discarding numbers, punctuation or turn boundaries.
                    yield (f'row:{index}/turn:{turn_index}', LCCC_TOKEN_SPACES.sub('', turn), {})
            else:
                if not isinstance(row, dict) or not isinstance(row.get('text'), str):
                    raise ValueError('Invalid mC4 raw record at row ' + str(index))
                metadata = {key: row[key] for key in ('url', 'timestamp') if key in row}
                # No legacy Han-ratio/prose filter: the supplied tokenizer owns
                # normalization and its documented empty/long-sentence filtering.
                yield f'row:{index}', row['text'], metadata


def extract(source, archive, output):
    counts = Counter()
    last_report = time.monotonic()
    code = {name: digest(ROOT / name) for name in
            ('prepare_raw_text.py', 'prepare.py', 'clean/chinese.py', 'clean/wikipedia.py')}
    if output.exists():
        manifest = json.loads((output / 'manifest.json').read_text())
        if manifest['source'] != source or manifest['code'] != code:
            raise ValueError('Existing raw-text extraction has different inputs/code: ' + source['id'])
        for name, expected in manifest['files'].items():
            if digest(output / name) != expected['sha256']:
                raise ValueError('Existing raw-text extraction checksum mismatch: ' + source['id'])
        print('Verified completed raw-text extraction: ' + source['id'], flush=True)
        return manifest
    with new_directory(output) as stage:
        with (stage / 'text.txt').open('w', encoding='utf-8', newline='\n') as text_file, \
                (stage / 'documents.jsonl').open('w', encoding='utf-8', newline='\n') as origins:
            for origin, raw, metadata in raw_documents(source, archive, counts):
                counts['documents'] += 1
                raw = raw.replace('\r\n', '\n').replace('\r', '\n')
                raw, removed = SURROGATES.subn('', raw)
                counts['surrogates_removed'] += removed
                first_line = counts['lines'] + 1
                document_lines = 0
                for line in io.StringIO(raw):
                    value = line[:-1] if line.endswith('\n') else line
                    text_file.write(value + '\n')
                    counts['lines'] += 1
                    counts['characters'] += len(value)
                    document_lines += 1
                origins.write(json.dumps({'origin': origin, 'first_line': first_line,
                                          'lines': document_lines, **metadata}, ensure_ascii=False) + '\n')
                if time.monotonic() - last_report >= 15:
                    print(f'{source["id"]}: {counts["records_read"]:,} raw records / '
                          f'{counts["documents"]:,} documents / {counts["lines"]:,} text lines', flush=True)
                    last_report = time.monotonic()
        manifest = {
            'schema_version': 1, 'extraction_contract': 'complete-raw-text-lines-v1',
            'source': source, 'counts': dict(counts), 'code': code,
            'scope': 'All eligible records in the complete pinned local raw archive; no character cap, '
                     'Han-only filtering, 4-character minimum, 96-character cutting, simplification or deduplication.',
            'extraction': 'JSON text/turns; Markdown prose; namespace-0 nonredirect Wikipedia current wikitext prose '
                          'with title. Existing markup readers remove code/templates/tables/references. '
                          'Line endings are LF; invalid surrogate code points are removed for valid UTF-8. '
                          'LCCC joins only spaces between adjacent Han/CJK punctuation tokens.',
            'files': {name: {'sha256': digest(stage / name), 'bytes': (stage / name).stat().st_size}
                      for name in ('text.txt', 'documents.jsonl')},
        }
        write_json(stage / 'manifest.json', manifest)
    print(f'Extracted {source["id"]}: {counts["documents"]:,} documents / {counts["lines"]:,} text lines', flush=True)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='all')
    parser.add_argument('--output', type=Path, default=CHINESE / 'prepared/raw-text-v1')
    parser.add_argument('--raw-root', type=Path, default=CHINESE / 'raw')
    args = parser.parse_args()
    sources = load_sources()
    if args.source not in {'all', *(source['id'] for source in sources)}:
        parser.error('Unknown source')
    args.output.mkdir(parents=True, exist_ok=True)
    for source in sources:
        if args.source not in ('all', source['id']):
            continue
        print('Verifying raw archive: ' + source['id'], flush=True)
        archive = verified_archive(source, args.raw_root)
        extract(source, archive, args.output / source['id'])
    for name in ('sources.lock.json', 'NOTICE.md'):
        target = args.output / name
        if not target.exists():
            shutil.copy2(CHINESE / name, target)
    for name in ('licenses', 'metadata'):
        target = args.output / name
        if not target.exists():
            shutil.copytree(CHINESE / name, target)


if __name__ == '__main__':
    main()
