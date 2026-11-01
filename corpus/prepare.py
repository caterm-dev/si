#!/usr/bin/env python3
"""Prepare separate, deduplicated Simplified Chinese text sources offline."""

import argparse
import bz2
from collections import Counter
import gzip
import importlib.metadata
import json
import re
from pathlib import Path
import shutil
import sqlite3
import tarfile
import time
import xml.etree.ElementTree as ET

if __package__:
    from .clean.chinese import markdown_text, segments, web_prose
    from .clean.wikipedia import wikitext
    from .common import CHINESE, LOCK, ROOT, digest, load_sources, new_directory, verified_archive, write_json
else:
    from clean.chinese import markdown_text, segments, web_prose
    from clean.wikipedia import wikitext
    from common import CHINESE, LOCK, ROOT, digest, load_sources, new_directory, verified_archive, write_json


def documents(source, path, counts, *, preserve_lccc_spacing=False, include_title=False):
    if source['kind'] == 'wikipedia':
        with bz2.open(path, 'rb') as handle:
            events = ET.iterparse(handle, events=('start', 'end'))
            _, root = next(events)
            namespace = root.tag.partition('}')[0] + '}' if root.tag.startswith('{') else ''
            for event, page in events:
                if event != 'end' or page.tag != namespace + 'page':
                    continue
                counts['records_read'] += 1
                if page.findtext(namespace + 'ns') != '0':
                    counts['nonarticle_pages'] += 1
                elif page.find(namespace + 'redirect') is not None:
                    counts['redirect_pages'] += 1
                else:
                    revision = page.find(namespace + 'revision')
                    if revision is None:
                        raise ValueError('Wikipedia page has no current revision')
                    page_id = page.findtext(namespace + 'id')
                    revision_id = revision.findtext(namespace + 'id')
                    if not page_id or not revision_id or not page_id.isdigit() or not revision_id.isdigit():
                        raise ValueError('Wikipedia page/revision has no numeric ID')
                    model = revision.findtext(namespace + 'model')
                    if model not in (None, 'wikitext'):
                        counts['nonwikitext_pages'] += 1
                    else:
                        text = revision.findtext(namespace + 'text') or ''
                        origin = f'https://zh.wikipedia.org/w/index.php?curid={page_id}&oldid={revision_id}'
                        title = page.findtext(namespace + 'title') or ''
                        prefix = title + '\n\n' if include_title and title else ''
                        yield origin, prefix + wikitext(text)
                # Clearing only the element leaves empty pages attached to the
                # root. Clear the root too, keeping memory independent of page count.
                page.clear()
                root.clear()
        return
    if source['kind'] in ('lccc', 'mc4'):
        with gzip.open(path, 'rt', encoding='utf-8') as handle:
            for index, line in enumerate(handle, 1):
                counts['records_read'] += 1
                row = json.loads(line)
                if source['kind'] == 'lccc':
                    if not isinstance(row, list) or not all(isinstance(turn, str) for turn in row):
                        raise ValueError('Invalid LCCC record at row ' + str(index))
                    for turn_index, turn in enumerate(row):
                        # This release is word-tokenized. Only its ASCII token spaces
                        # are removed; turns and punctuation always remain boundaries.
                        restored = (re.sub(r'(?<=[\u3400-\u9fff，。！？；：、]) +'
                                           r'(?=[\u3400-\u9fff，。！？；：、])', '', turn)
                                    if preserve_lccc_spacing else turn.replace(' ', ''))
                        yield f'row:{index}/turn:{turn_index}', restored
                else:
                    if not isinstance(row, dict) or not isinstance(row.get('text'), str):
                        raise ValueError('Invalid mC4 record at row ' + str(index))
                    if web_prose(row['text']):
                        yield f'row:{index}', row['text']
                    else:
                        counts['nonprose_documents'] += 1
        return
    # A pinned tarball has deterministic member order. Stream once rather than
    # sorting members and repeatedly seeking backwards through a gzip archive.
    with tarfile.open(path, 'r|gz') as archive:
        for member in archive:
            relative = member.name.partition('/')[2]
            if (not member.isfile() or not relative.startswith(source['prefix'])
                    or not relative.endswith(('.md', '.html'))):
                continue
            if member.size > 8 * 1024 * 1024:
                raise ValueError('Documentation file exceeds 8 MiB: ' + relative)
            counts['records_read'] += 1
            with archive.extractfile(member) as handle:
                text = handle.read().decode('utf-8')
            yield relative, markdown_text(text)


def prepare_source(source, archive, output, converter, max_chars):
    output.mkdir()
    counts = Counter()
    # SQLite stores exact text as its key, not a truncated hash, and bounds RAM.
    # The retained origin is the first source occurrence of each emitted line.
    database = sqlite3.connect(output / 'dedup.sqlite')
    database.execute('CREATE TABLE seen (text TEXT PRIMARY KEY) WITHOUT ROWID')
    limited = False
    progress_at = time.monotonic()
    try:
        with (output / 'text.txt').open('w', encoding='utf-8', newline='\n') as text_file, \
                (output / 'origins.jsonl').open('w', encoding='utf-8', newline='\n') as origins:
            for origin, text in documents(source, archive, counts):
                counts['documents_read'] += 1
                if time.monotonic() - progress_at >= 30:
                    print(f'{source["id"]}: processed {counts["documents_read"]:,} documents, '
                          f'{counts["characters"]:,} unique characters', flush=True)
                    progress_at = time.monotonic()
                for piece in segments(text, converter):
                    counts['segments_before_dedup'] += 1
                    inserted = database.execute('INSERT OR IGNORE INTO seen VALUES (?)', (piece,)).rowcount
                    if not inserted:
                        counts['duplicate_segments'] += 1
                        continue
                    if max_chars and counts['characters'] + len(piece) > max_chars:
                        limited = True
                        break
                    text_file.write(piece + '\n')
                    origins.write(json.dumps(origin, ensure_ascii=False) + '\n')
                    counts['lines'] += 1
                    counts['characters'] += len(piece)
                if limited:
                    break
    finally:
        database.close()
    (output / 'dedup.sqlite').unlink()
    if not counts['lines']:
        raise ValueError('Source produced no usable Chinese text: ' + source['id'])
    result = {
        'source': source, 'counts': dict(counts), 'max_characters': max_chars,
        'stopped_at_limit': limited, 'scope': 'pinned source subset; not the complete upstream corpus',
        'files': {name: {'sha256': digest(output / name), 'bytes': (output / name).stat().st_size}
                  for name in ('text.txt', 'origins.jsonl')},
    }
    write_json(output / 'manifest.json', result)
    print(f'{source["id"]}: {counts["lines"]:,} lines / {counts["characters"]:,} characters', flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='all')
    parser.add_argument('--raw-root', type=Path, default=CHINESE / 'raw')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--max-chars', type=int, default=10_000_000,
                        help='Unique output characters per source; 0 processes the complete pinned subset')
    args = parser.parse_args()
    if args.max_chars < 0:
        parser.error('--max-chars must be nonnegative')
    sources = load_sources()
    if args.source != 'all' and args.source not in {source['id'] for source in sources}:
        parser.error('Unknown source: ' + args.source)
    sources = [source for source in sources if args.source in ('all', source['id'])]
    archives = [(source, verified_archive(source, args.raw_root)) for source in sources]
    from opencc import OpenCC
    converter = OpenCC('t2s')
    with new_directory(args.output) as staged:
        results = [prepare_source(source, archive, staged / source['id'], converter, args.max_chars)
                   for source, archive in archives]
        shutil.copytree(CHINESE / 'licenses', staged / 'licenses')
        if (CHINESE / 'metadata').exists():
            shutil.copytree(CHINESE / 'metadata', staged / 'metadata')
        shutil.copy2(CHINESE / 'NOTICE.md', staged / 'NOTICE.md')
        shutil.copy2(LOCK, staged / LOCK.name)
        write_json(staged / 'manifest.json', {
            'schema_version': 1, 'language': 'zh-Hans', 'source_lock_sha256': digest(LOCK),
            'normalization': {'opencc': importlib.metadata.version('opencc-python-reimplemented'),
                              'config': 't2s', 'minimum_characters': 4, 'maximum_characters': 96},
            'code': {name: digest(ROOT / name) for name in
                     ('prepare.py', 'common.py', 'clean/chinese.py', 'clean/wikipedia.py')},
            'sources': results, 'split_assignment': None,
            'notes': 'Text preparation only. No sentence Pinyin labels, model training or app integration.',
        })


if __name__ == '__main__':
    main()
