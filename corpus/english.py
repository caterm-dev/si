#!/usr/bin/env python3
"""Explicit acquisition, offline preparation and verification of English dialogue."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request

if __package__:
    from .common import ROOT, digest, new_directory, write_json
    from .clean.dialogue import conversations
else:
    from common import ROOT, digest, new_directory, write_json
    from clean.dialogue import conversations

ENGLISH = ROOT / 'english'
LOCK = ENGLISH / 'sources.lock.json'
SPLITS = {'train', 'validation', 'test', 'unsplit', 'validation-frequent',
          'validation-rare', 'test-frequent', 'test-rare'}
READERS = {'convai2', 'bst', 'topical-chat', 'taskmaster', 'abcd', 'sgd', 'oasst1'}


def relative_path(root, name):
    path = Path(name)
    if path.is_absolute() or not path.parts or '..' in path.parts:
        raise ValueError('Invalid corpus relative path')
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise ValueError('Corpus path escapes its root')
    return resolved


def load_lock(path=LOCK, data_root=ENGLISH):
    lock = json.loads(path.read_text(encoding='utf-8'))
    if lock.get('schema_version') != 1 or lock.get('language') != 'en':
        raise ValueError('Unsupported English source lock')
    seen = set()
    for source in lock['sources']:
        identity = source['id']
        if (identity in seen or not re.fullmatch('[a-z][a-z0-9-]*', identity)
                or source['reader'] not in READERS
                or not re.fullmatch('[0-9a-f]{40}', source['revision'])
                or not source['files'] or not source['documents']):
            raise ValueError('Invalid English source record')
        paths = set()
        for entry in source['files'] + source['documents']:
            relative_path(data_root, entry['path'])
            if (entry['path'] in paths
                    or not re.fullmatch('[0-9a-f]{64}', entry['sha256'])
                    or type(entry['size']) is not int or entry['size'] <= 0
                    or not entry['url'].startswith('https://')):
                raise ValueError('Invalid English source file')
            paths.add(entry['path'])
        for document in source['documents']:
            if Path(document['path']).parts[0] not in ('licenses', 'metadata'):
                raise ValueError('Invalid attribution path')
            verify_file(relative_path(data_root, document['path']), document)
        seen.add(identity)
    return lock


def verify_file(path, entry):
    if path.stat().st_size != entry['size'] or digest(path) != entry['sha256']:
        raise ValueError('Corpus checksum mismatch: ' + entry['path'])


def verify_raw(source, raw_root):
    for entry in source['files']:
        verify_file(relative_path(raw_root / source['id'], entry['path']), entry)


def fetch(source, raw_root):
    """No source resolution here: only the reviewed frozen bytes may be fetched."""
    for entry in source['files']:
        target = relative_path(raw_root / source['id'], entry['path'])
        if target.exists():
            verify_file(target, entry)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.get('hub_repository'):
            subprocess.run([
                'hf', 'download', source['hub_repository'], entry['path'],
                '--type', 'dataset', '--revision', source['revision'],
                '--local-dir', str(raw_root / source['id']), '--quiet',
            ], check=True)
            verify_file(target, entry)
            continue
        partial = target.with_suffix(target.suffix + '.part')
        try:
            request = urllib.request.Request(entry['url'], headers={
                'User-Agent': 'SI-public-corpus-preparation'})
            with urllib.request.urlopen(request, timeout=180) as response, partial.open('wb') as out:
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > entry['size']:
                        raise ValueError('Download exceeds pinned size')
                    out.write(chunk)
            verify_file(partial, entry)
            partial.replace(target)
        finally:
            partial.unlink(missing_ok=True)
    print('Verified ' + source['id'], flush=True)


def validate_conversation(record):
    required = {'id', 'group', 'split', 'origin', 'method', 'turns'}
    if (set(record) not in (required, required | {'upstream_example_splits'})
            or record['split'] not in SPLITS
            or any(not isinstance(record[key], str) or not record[key]
                   for key in ('id', 'group', 'origin', 'method'))
            or not isinstance(record['turns'], list) or not record['turns']):
        raise ValueError('Invalid conversation envelope')
    if 'upstream_example_splits' in record:
        memberships = record['upstream_example_splits']
        if (not isinstance(memberships, list) or memberships != sorted(set(memberships))
                or set(memberships) - {'train', 'validation', 'test'}
                or record['split'] != 'unsplit'):
            raise ValueError('Invalid upstream example split evidence')
    ids = set()
    for turn in record['turns']:
        if (set(turn) not in ({'id', 'speaker', 'text'}, {'id', 'speaker', 'text', 'parent'})
                or any(not isinstance(turn[key], str) or not turn[key]
                       for key in ('id', 'speaker', 'text'))
                or not turn['text'].strip() or turn['id'] in ids
                or any(ord(c) < 32 and c not in '\n\r\t' for c in turn['text'])):
            raise ValueError('Invalid conversation turn')
        if 'parent' in turn and turn['parent'] is not None and not isinstance(turn['parent'], str):
            raise ValueError('Invalid conversation parent')
        ids.add(turn['id'])


def statistics(records):
    counts = Counter(conversations=0, turns=0, characters=0)
    for record in records:
        counts['conversations'] += 1
        counts['turns'] += len(record['turns'])
        counts['characters'] += sum(len(turn['text']) for turn in record['turns'])
    return dict(counts)


def prepare(source_ids, output, raw_root=ENGLISH / 'raw', lock_path=LOCK):
    lock = load_lock(lock_path, lock_path.parent)
    selected = [s for s in lock['sources'] if source_ids == ['all'] or s['id'] in source_ids]
    for source in selected:
        verify_raw(source, raw_root)
    with new_directory(output) as staged:
        shutil.copy2(lock_path, staged / 'sources.lock.json')
        documentation = {}
        notice = lock_path.parent / 'NOTICE.md'
        if notice.exists():
            shutil.copy2(notice, staged / 'NOTICE.md')
            documentation['NOTICE.md'] = {'size': notice.stat().st_size, 'sha256': digest(notice)}
        # Copy all attribution because the frozen source lock verifies every entry.
        for source in lock['sources']:
            for entry in source['documents']:
                target = relative_path(staged, entry['path'])
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(relative_path(lock_path.parent, entry['path']), target)
        reports = []
        for source in selected:
            identity = source['id']
            directory = staged / identity
            directory.mkdir()
            counters = Counter()
            splits = {}
            handles = {}
            ids = set()
            groups = {}
            content_splits = {}
            try:
                for record in conversations(source, raw_root / identity, counters):
                    validate_conversation(record)
                    key = (record['split'], record['id'])
                    if key in ids:
                        raise ValueError('Duplicate conversation ID: ' + identity)
                    ids.add(key)
                    previous = groups.setdefault(record['group'], record['split'])
                    if previous != record['split']:
                        raise ValueError('Conversation group crosses splits: ' + identity)
                    fingerprint = hashlib.sha256(json.dumps(
                        [turn['text'] for turn in record['turns']], ensure_ascii=False,
                        separators=(',', ':')).encode()).hexdigest()
                    previous_split = content_splits.setdefault(fingerprint, record['split'])
                    if previous_split != record['split']:
                        # Keep upstream held-out data and report overlap; never silently
                        # promote an upstream held-out conversation into training.
                        counters['cross_split_exact_conversations'] += 1
                    split = record['split']
                    if split not in handles:
                        handles[split] = (directory / (split + '.jsonl')).open('w', encoding='utf-8')
                        splits[split] = Counter(conversations=0, turns=0, characters=0)
                    handles[split].write(json.dumps(record, ensure_ascii=False, separators=(',', ':')) + '\n')
                    splits[split].update(statistics([record]))
            finally:
                for handle in handles.values():
                    handle.close()
            if not splits:
                raise ValueError('No conversations selected: ' + identity)
            report = {'id': identity, 'source': source, 'splits': dict(sorted(splits.items())),
                      'selection_counts': dict(sorted(counters.items())), 'files': {}}
            for path in sorted(directory.glob('*.jsonl')):
                report['files'][path.name] = {'size': path.stat().st_size, 'sha256': digest(path)}
            write_json(directory / 'manifest.json', report)
            reports.append(report)
            print('Prepared ' + identity + ': ' + str(sum(s['turns'] for s in splits.values()))
                  + ' turns', flush=True)
        write_json(staged / 'manifest.json', {
            'schema_version': 1, 'language': 'en', 'format': 'si-dialogue-v1',
            'source_lock_sha256': digest(staged / 'sources.lock.json'),
            'documentation': documentation,
            'code': {str(path.relative_to(ROOT.parent)): digest(path) for path in
                     (Path(__file__), ROOT / 'clean/dialogue.py', ROOT / 'common.py')},
            'sources': reports,
        })
    return check(output)


def check(bundle):
    root = json.loads((bundle / 'manifest.json').read_text(encoding='utf-8'))
    lock = load_lock(bundle / 'sources.lock.json', bundle)
    if (root.get('format') != 'si-dialogue-v1' or root.get('language') != 'en'
            or root.get('schema_version') != 1
            or digest(bundle / 'sources.lock.json') != root['source_lock_sha256']):
        raise ValueError('Invalid English bundle manifest')
    sources = {s['id']: s for s in lock['sources']}
    for name, entry in root.get('documentation', {}).items():
        verify_file(relative_path(bundle, name), dict(entry, path=name))
    report = []
    identities = set()
    for source in root['sources']:
        identity = source['id']
        if identity in identities or source['source'] != sources[identity]:
            raise ValueError('Bundle source metadata mismatch')
        identities.add(identity)
        directory = relative_path(bundle, identity)
        if json.loads((directory / 'manifest.json').read_text(encoding='utf-8')) != source:
            raise ValueError('Per-source manifest mismatch')
        if set(source['files']) != {s + '.jsonl' for s in source['splits']}:
            raise ValueError('Unexpected split file set')
        if {p.name for p in directory.glob('*.jsonl')} != set(source['files']):
            raise ValueError('Unlisted split file')
        groups = {}
        ids = set()
        for split, counts in source['splits'].items():
            if split not in SPLITS:
                raise ValueError('Invalid split')
            name = split + '.jsonl'
            verify_file(directory / name, dict(source['files'][name], path=identity + '/' + name))
            measured = Counter(conversations=0, turns=0, characters=0)
            with (directory / name).open(encoding='utf-8') as handle:
                for line in handle:
                    if not line.endswith('\n'):
                        raise ValueError('Incomplete JSONL record')
                    record = json.loads(line)
                    validate_conversation(record)
                    key = (split, record['id'])
                    if record['split'] != split or key in ids:
                        raise ValueError('Conversation split/identity mismatch')
                    ids.add(key)
                    if groups.setdefault(record['group'], split) != split:
                        raise ValueError('Conversation group crosses splits')
                    measured.update(statistics([record]))
            if dict(measured) != counts:
                raise ValueError('Conversation counts mismatch')
        totals = Counter(conversations=0, turns=0, characters=0)
        for counts in source['splits'].values():
            totals.update(counts)
        report.append({'id': identity, **dict(totals), 'splits': source['splits'],
                       'license': source['source']['license']})
    totals = Counter(conversations=0, turns=0, characters=0)
    for source in report:
        totals.update({key: source[key] for key in totals})
    return {'schema_version': 1, 'source_lock_sha256': digest(bundle / 'sources.lock.json'),
            'bundle_manifest_sha256': digest(bundle / 'manifest.json'),
            'sources': report, 'totals': dict(totals)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['fetch', 'prepare', 'check'])
    parser.add_argument('--source', action='append', default=[])
    parser.add_argument('--raw-root', type=Path, default=ENGLISH / 'raw')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--check', action='store_true', help='Verify cached downloads without network')
    args = parser.parse_args()
    if args.report and args.report.exists():
        parser.error('Choose a new report path')
    if args.stage == 'check':
        if not args.bundle:
            parser.error('check requires --bundle')
        report = check(args.bundle)
    else:
        lock = load_lock()
        identities = args.source or ['all']
        known = {s['id'] for s in lock['sources']}
        if set(identities) - known - {'all'} or ('all' in identities and identities != ['all']):
            parser.error('Invalid source selection')
        if args.stage == 'fetch':
            for source in lock['sources']:
                if identities == ['all'] or source['id'] in identities:
                    if args.check:
                        verify_raw(source, args.raw_root)
                        print('Verified ' + source['id'], flush=True)
                    else:
                        fetch(source, args.raw_root)
            return
        if not args.output:
            parser.error('prepare requires a new --output directory')
        report = prepare(identities, args.output, args.raw_root)
    if args.report:
        write_json(args.report, report)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
