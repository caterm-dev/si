"""Prepare unused public corpus groups with the current student's frozen tokenizer.

Keep this entry point outside the trainer's hashed module set so preparation
can run while the original experiment is training, without breaking resume.
"""

import argparse
from collections import Counter
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import time

import numpy as np

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

from corpus.common import new_directory
from llm.pinyin_to_text.common import normalized, read_jsonl
from llm.reranker_small.tokenizer import Tokenizer
from llm.reranker_large.corpus_data import (
    BUNDLES, CATEGORIES, Snapshot, ingest, load_mixture, ordered_rows, progress, target_tokens,
)
from llm.reranker_large.data import checked_file, manifest_at
from llm.reranker_large.prepare import copy_provenance, finish_manifest
from llm.reranker_large.settings import (
    ROOT, SPLITS, code_identity, file_hash, fingerprint, load_config, write_json,
)


def paragraphs(text):
    return {fingerprint(value) for line in text.splitlines()
            if len(value := normalized(line)) >= 32}


def create_index(connection):
    connection.executescript('''
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE TABLE groups (source TEXT, grp TEXT, PRIMARY KEY(source,grp));
        CREATE TABLE docs (id TEXT PRIMARY KEY,source TEXT,grp TEXT,split TEXT,
                           category TEXT,priority TEXT,origin TEXT,text TEXT,upstream TEXT);
        CREATE TABLE prior_docs (id TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE prior_groups (source TEXT,grp TEXT,PRIMARY KEY(source,grp)) WITHOUT ROWID;
        CREATE TABLE prior_paragraphs (id TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE selected_paragraphs (id TEXT PRIMARY KEY,split TEXT) WITHOUT ROWID;
        CREATE TABLE selected (id TEXT PRIMARY KEY) WITHOUT ROWID;
    ''')


def index_parents(connection, roots, config):
    tokenizer, locks, pins = None, [], []
    for root in roots:
        root = Path(root).resolve()
        manifest = manifest_at(root, 'si-character-lm')
        limits = {k: config['model'][k] for k in ('vocab_size', 'context')}
        if manifest['model_limits'] != limits:
            raise ValueError('Parent vocabulary/context limits differ')
        if manifest.get('corpus_sampling', {}).get('seed', config['seed']) != config['seed']:
            raise ValueError('Keep the parent split seed unchanged')
        path = checked_file(root, manifest, 'tokenizer.json')
        current = Tokenizer.load(path)
        if (current.vocab_size != limits['vocab_size'] or current.digest != manifest['tokenizer_digest']
                or (tokenizer and current.digest != tokenizer.digest)):
            raise ValueError('Excluded datasets must share the frozen parent tokenizer')
        tokenizer = tokenizer or current
        pin = file_hash(root / 'manifest.json')
        pins.append((root / 'manifest.json', pin))
        pins.append((path, manifest['files']['tokenizer.json']))
        documents = {}
        for split in SPLITS:
            name = f'{split}.documents.jsonl'
            path = checked_file(root, manifest, name)
            pins.append((path, manifest['files'][name]))
            documents[split] = manifest['files'][name]
            count, start = 0, time.monotonic()
            for row in read_jsonl(path):
                if (not all(isinstance(row.get(k), str) and row[k] for k in ('id', 'source', 'group', 'text'))
                        or row['id'] != fingerprint(normalized(row['text']))):
                    raise ValueError('Invalid parent document identity')
                connection.execute('INSERT OR IGNORE INTO prior_docs VALUES (?)', (row['id'],))
                connection.execute('INSERT OR IGNORE INTO prior_groups VALUES (?,?)', (row['source'], row['group']))
                connection.executemany('INSERT OR IGNORE INTO prior_paragraphs VALUES (?)',
                                       ((p,) for p in paragraphs(row['text'])))
                count += 1
                if time.monotonic() - start >= 10:
                    progress('index-parent', split=split, documents=count)
                    start = time.monotonic()
            if count != manifest['splits'][split]['documents']:
                raise ValueError('Parent document count differs from manifest')
            connection.commit()
            progress('index-parent-complete', split=split, documents=count)
        locks.append(dict(dataset_id=manifest['dataset_id'], manifest_sha256=pin,
                          tokenizer_digest=current.digest, document_sha256=documents))
    return tokenizer, locks, pins


def select_unused(connection, config, mixture, tokenizer, audit, counts, *, allow_heldout_shortfall=False):
    counts['excluded_prior_documents_or_groups'] = connection.execute('''
        DELETE FROM docs WHERE EXISTS (SELECT 1 FROM prior_docs p WHERE p.id=docs.id)
        OR EXISTS (SELECT 1 FROM prior_groups p WHERE p.source=docs.source AND p.grp=docs.grp)
    ''').rowcount
    connection.execute('CREATE INDEX sampling_order ON docs(category,split,priority,source,grp)')
    connection.commit()
    fraction = dict(train=1-mixture['test_fraction']-mixture['validation_fraction'],
                    validation=mixture['validation_fraction'], test=mixture['test_fraction'])
    selection, sources = {}, Counter()
    with (audit / 'documents.jsonl').open('w', encoding='utf-8') as output:
        for split in ('test', 'validation', 'train'):
            selection[split] = {}
            for category, share in mixture['shares'].items():
                budget = max(1, round(mixture['train_target_tokens'] * fraction[split] / fraction['train'] * share))
                tokens = documents = 0
                last_report = time.monotonic()
                for identity, source, group, origin, text, upstream in ordered_rows(connection, category, split):
                    keys = paragraphs(text)
                    if any(connection.execute('SELECT 1 FROM prior_paragraphs WHERE id=?', (key,)).fetchone()
                           for key in keys):
                        counts[f'{split}_excluded_prior_paragraph_groups'] += 1
                        continue
                    if any((row := connection.execute('SELECT split FROM selected_paragraphs WHERE id=?', (key,)).fetchone())
                           and row[0] != split for key in keys):
                        counts[f'{split}_cross_split_paragraph_groups_excluded'] += 1
                        continue
                    connection.executemany('INSERT OR IGNORE INTO selected_paragraphs VALUES (?,?)',
                                           ((key, split) for key in keys))
                    connection.execute('INSERT INTO selected VALUES (?)', (identity,))
                    record = dict(source=source, origin=origin, group=group, split=split, text=text,
                                  upstream_split=upstream, corpus_document_id=identity)
                    output.write(json.dumps(record, ensure_ascii=False) + '\n')
                    tokens += target_tokens(text, tokenizer)
                    documents += 1
                    sources[source] += 1
                    if time.monotonic() - last_report >= 10:
                        progress('select-unused', split=split, category=category, targets=tokens, documents=documents)
                        last_report = time.monotonic()
                    if tokens >= budget:
                        break
                shortfall = max(0, budget-tokens)
                selection[split][category] = dict(requested_targets=budget, actual_targets=tokens,
                                                  documents=documents, shortfall_targets=shortfall)
                progress('sampled-unused', split=split, category=category, **selection[split][category])
                if shortfall:
                    if split != 'train' and allow_heldout_shortfall:
                        progress('heldout-shortfall', split=split, category=category,
                                 requested_targets=budget, actual_targets=tokens, shortfall_targets=shortfall)
                    else:
                        hint = ('use --allow-heldout-shortfall to retain measured held-out counts'
                                if split != 'train' else 'reduce the budget or review the mixture/sources')
                        raise ValueError(f'Insufficient unused {split}/{category} targets: {tokens} < {budget}; '
                                         'no old documents were reused; ' + hint)
            if not any(value['documents'] for value in selection[split].values()):
                raise ValueError(f'No unused {split} documents; empty splits cannot be published')
    return selection, sources


def pack(connection, tokenizer, config, staged, split):
    stats, by_source = Counter(), {}
    start_time = time.monotonic()
    with (staged / f'{split}.tokens.bin').open('wb') as tokens, \
            (staged / f'{split}.windows.bin').open('wb') as windows, \
            (staged / f'{split}.documents.jsonl').open('w', encoding='utf-8') as stream:
        rows = connection.execute('SELECT d.id,d.source,d.origin,d.grp,d.text FROM docs d '
                                  'JOIN selected s ON s.id=d.id WHERE d.split=? ORDER BY d.id', (split,))
        for identity, source, origin, group, text in rows:
            ids = tokenizer.encode(text)
            base = stats['tokens']
            tokens.write(np.asarray(ids, dtype='<u2').tobytes())
            for start in range(0, len(ids)-1, config['model']['context']):
                length = min(config['model']['context']+1, len(ids)-start)
                windows.write(np.asarray([base+start, length], dtype='<u8').tobytes())
                stats['windows'] += 1
                stats['targets'] += length-1
            fallback = sum(ord(c) > 127 and c not in tokenizer.lookup for c in text)
            non_ascii = sum(ord(c) > 127 for c in text)
            stats.update(documents=1, characters=len(text), tokens=len(ids),
                         byte_fallback_scalars=fallback, non_ascii_scalars=non_ascii)
            by_source.setdefault(source, Counter()).update(documents=1, targets=len(ids)-1, characters=len(text),
                byte_fallback_scalars=fallback, non_ascii_scalars=non_ascii)
            stream.write(json.dumps(dict(id=identity, source=source, origin=origin, group=group, text=text),
                                    ensure_ascii=False) + '\n')
            if time.monotonic() - start_time >= 10:
                progress('encode-unused', split=split, documents=stats['documents'], targets=stats['targets'])
                start_time = time.monotonic()
    if not stats['windows']:
        raise ValueError('Every split must have windows')
    return dict(stats), {name: dict(value) for name, value in by_source.items()}


def prepare(config_path, mixture_path, prepared_root, notices_root, parent_data, output, *,
            train_tokens=100000000, dialogue_root=None, exclude_data=(), allow_heldout_shortfall=False):
    config, mixture = load_config(config_path), load_mixture(mixture_path)
    if config['stage'] != 'pretrain' or type(train_tokens) is not int or train_tokens <= 0:
        raise ValueError('Use a pretraining configuration and positive target-token budget')
    mixture['train_target_tokens'] = train_tokens
    roots = [Path(parent_data).resolve(), *(Path(p).resolve() for p in exclude_data)]
    if len(set(roots)) != len(roots):
        raise ValueError('Duplicate excluded dataset paths')
    output = Path(output).resolve()
    if any(output == p or output.is_relative_to(p) or p.is_relative_to(output) for p in roots):
        raise ValueError('Use an independent output directory outside all excluded bundles')
    with new_directory(output) as staged:
        audit = staged / 'import'
        audit.mkdir()
        connection = sqlite3.connect(staged / 'sampling.sqlite')
        counts = Counter()
        try:
            create_index(connection)
            tokenizer, parents, pins = index_parents(connection, roots, config)
            snapshots = [Snapshot(prepared_root, name, notices_root, audit,
                directory=dialogue_root if name == 'dialogue' else None) for name in BUNDLES]
            for snapshot in snapshots:
                progress('read-start', source=snapshot.name)
                ingest(connection, snapshot, config['seed'], mixture, config['data']['max_document_characters'], counts)
                connection.commit()
            selection, selected_sources = select_unused(connection, config, mixture, tokenizer, audit, counts,
                                                        allow_heldout_shortfall=allow_heldout_shortfall)
            sources = [s for snapshot in snapshots for s in snapshot.sources if s['id'] in selected_sources]
            attribution = {str(p.relative_to(audit)): file_hash(p)
                           for p in sorted((audit / 'attribution').rglob('*')) if p.is_file()}
            write_json(audit / 'provenance.json', dict(schema_version=1, sources=sources, files=attribution))
            sources, provenance_pin = copy_provenance(audit / 'provenance.json', staged)
            shutil.copyfile(checked_file(roots[0], manifest_at(roots[0], 'si-character-lm'), 'tokenizer.json'),
                            staged / 'tokenizer.json')
            splits, source_counts = {}, {}
            for split in SPLITS:
                splits[split], source_counts[split] = pack(connection, tokenizer, config, staged, split)
        finally:
            connection.close()
        (staged / 'sampling.sqlite').unlink()
        if Tokenizer.load(staged / 'tokenizer.json').digest != tokenizer.digest:
            raise ValueError('Frozen tokenizer changed')
        for path, pin in pins:
            if file_hash(path) != pin:
                raise ValueError('Excluded dataset changed during preparation')
        for snapshot in snapshots:
            snapshot.verify_unchanged()
        actual = {}
        for split in SPLITS:
            categories = Counter()
            for source, stats in source_counts[split].items():
                categories[CATEGORIES[source]] += stats['targets']
            actual[split] = dict(targets=splits[split]['targets'], by_category=dict(categories),
                shares={category: categories[category]/splits[split]['targets'] for category in mixture['shares']})
            assert sum(x['actual_targets'] for x in selection[split].values()) == splits[split]['targets']
        write_json(audit / 'mixture.json', mixture)
        write_json(audit / 'excluded-datasets.json', parents)
        write_json(staged / 'sampling-report.json', dict(selection=selection, actual=actual, counts=dict(counts),
            allow_heldout_shortfall=allow_heldout_shortfall,
            note='Exact frozen-tokenizer quotas; complete groups may overshoot. Old documents/groups and '
                 'normalized paragraphs of at least 32 characters are excluded across every old split. '
                 'No semantic/template-near-duplicate guarantee. No standalone English corpus.'))
        manifest = finish_manifest(staged, dict(schema_version=1, kind='si-character-lm',
            model_limits={k: config['model'][k] for k in ('vocab_size', 'context')},
            tokenizer_digest=tokenizer.digest, tokenizer_origin='frozen-parent',
            parent_dataset_id=parents[0]['dataset_id'], excluded_dataset_ids=[p['dataset_id'] for p in parents],
            splits=splits, sources=sources, source_counts=source_counts, selection_counts=dict(counts),
            document_sha256=file_hash(audit / 'documents.jsonl'), provenance_sha256=provenance_pin,
            preparation_code=file_hash(Path(__file__)), dependency_code_identity=code_identity(),
            corpus_sampling=dict(mixture=mixture, seed=config['seed'], frozen_tokenizer=True,
                allow_heldout_shortfall=allow_heldout_shortfall,
                prepared_manifest_hashes={s.name: s.pin for s in snapshots}, report='sampling-report.json')))
        progress('complete', dataset_id=manifest['dataset_id'], training_targets=splits['train']['targets'])
        return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'configs/pretrain.json')
    parser.add_argument('--mixture-config', type=Path, default=ROOT / 'configs/corpus.json')
    parser.add_argument('--prepared-root', type=Path, default=REPO / 'corpus/chinese/prepared/raw-text-v2')
    parser.add_argument('--notices-root', type=Path, default=REPO / 'corpus/chinese')
    parser.add_argument('--dialogue-root', type=Path)
    parser.add_argument('--parent-data', type=Path, default=ROOT / 'data/prepared/student-15m-v1/lm')
    parser.add_argument('--exclude-data', type=Path, action='append', default=[],
                        help='Additional earlier bundles to exclude in full; repeat for later batches')
    parser.add_argument('--train-tokens', type=int, default=100000000)
    parser.add_argument('--allow-heldout-shortfall', action='store_true',
                        help='Retain and report validation/test category shortfalls; training quotas remain strict')
    parser.add_argument('--output', type=Path, default=ROOT / 'data/prepared/student-15m-extra-v1/lm')
    args = parser.parse_args()
    prepare(args.config, args.mixture_config, args.prepared_root, args.notices_root,
            args.parent_data, args.output, train_tokens=args.train_tokens,
            dialogue_root=args.dialogue_root, exclude_data=args.exclude_data,
            allow_heldout_shortfall=args.allow_heldout_shortfall)


if __name__ == '__main__':
    main()
