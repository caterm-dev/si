#!/usr/bin/env python3
"""Verify a prepared Chinese text bundle and report its measured contents."""

import argparse
import json
from pathlib import Path

from clean.chinese import HAN
from common import digest, load_sources, write_json


def check(bundle):
    manifest = json.loads((bundle / 'manifest.json').read_text(encoding='utf-8'))
    lock_path = bundle / 'sources.lock.json'
    sources = {source['id']: source for source in load_sources(lock_path, bundle)}
    if digest(bundle / 'sources.lock.json') != manifest['source_lock_sha256']:
        raise ValueError('Bundle source lock checksum mismatch')
    records = []
    for source in manifest['sources']:
        identity = source['source']['id']
        if source['source'] != sources[identity]:
            raise ValueError('Source metadata mismatch: ' + identity)
        directory = bundle / identity
        if json.loads((directory / 'manifest.json').read_text(encoding='utf-8')) != source:
            raise ValueError('Per-source manifest mismatch: ' + identity)
        for name, expected in source['files'].items():
            path = directory / name
            if path.stat().st_size != expected['bytes'] or digest(path) != expected['sha256']:
                raise ValueError('Output checksum mismatch: ' + identity + '/' + name)
        lines = characters = origins = 0
        with (directory / 'text.txt').open(encoding='utf-8') as handle:
            for line in handle:
                if not line.endswith('\n') or not 4 <= len(line) - 1 <= 96 or not HAN.fullmatch(line[:-1]):
                    raise ValueError('Invalid cleaned Chinese line: ' + identity)
                lines += 1
                characters += len(line) - 1
        with (directory / 'origins.jsonl').open(encoding='utf-8') as handle:
            for line in handle:
                if not isinstance(json.loads(line), str):
                    raise ValueError('Invalid origin: ' + identity)
                origins += 1
        if (lines != origins or lines != source['counts']['lines']
                or characters != source['counts']['characters']):
            raise ValueError('Output count mismatch: ' + identity)
        documents = [source['source'][key] for key in ('license_document', 'dataset_card')
                     if key in source['source']]
        documents += source['source'].get('additional_documents', [])
        for document in documents:
            if digest(bundle / document['path']) != document['sha256']:
                raise ValueError('Bundled attribution checksum mismatch: ' + identity)
        records.append({
            'id': identity, 'lines': lines, 'characters': characters,
            'text_sha256': source['files']['text.txt']['sha256'],
            'origins_sha256': source['files']['origins.jsonl']['sha256'],
            'stopped_at_limit': source['stopped_at_limit'],
            'license': source['source']['license'],
        })
    return {'schema_version': 1, 'source_lock_sha256': digest(lock_path),
            'bundle_manifest_sha256': digest(bundle / 'manifest.json'),
            'sources': records, 'total_lines': sum(row['lines'] for row in records),
            'total_characters': sum(row['characters'] for row in records)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = check(args.bundle)
    if args.report:
        if args.report.exists():
            parser.error('Choose a new report path; existing reports are preserved')
        write_json(args.report, report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
