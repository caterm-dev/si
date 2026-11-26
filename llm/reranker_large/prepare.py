"""Explicit offline document/pool preparation. No default corpus or invented labels."""

from collections import Counter
import json
from pathlib import Path
import shutil
import sqlite3
import time

import numpy as np

from corpus.common import new_directory
from llm.pinyin_to_text.common import normalized, read_jsonl
from llm.reranker_small.tokenizer import fit_counts
from .data import PoolWriter, checked_file, manifest_at
from .settings import SPLITS, file_hash, fingerprint, load_config, read_json, write_json


def finish_manifest(staged, value):
    value['files'] = {str(p.relative_to(staged)): file_hash(p)
                      for p in sorted(staged.rglob('*')) if p.is_file() and p != staged / 'manifest.json'}
    value['dataset_id'] = fingerprint(value)
    write_json(staged / 'manifest.json', value)
    return value


def copy_provenance(path, staged):
    path = Path(path).resolve()
    pin = file_hash(path)
    value = read_json(path)
    sources = value.get('sources')
    if (value.get('schema_version') != 1 or not isinstance(sources, list) or not sources
            or any(not isinstance(s, dict) or any(not isinstance(s.get(k), str) or not s[k].strip()
                      for k in ('id', 'origin', 'revision', 'license')) for s in sources)
            or len({s['id'] for s in sources}) != len(sources)):
        raise ValueError('Provenance needs unique sources with origin, revision and actual data terms')
    for name, expected in value.get('files', {}).items():
        source = (path.parent / name).resolve()
        if (Path(name).is_absolute() or not source.is_relative_to(path.parent)
                or file_hash(source) != expected):
            raise ValueError('Attribution path/checksum mismatch')
        target = staged / 'metadata' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if file_hash(target) != expected:
            raise ValueError('Attribution changed during copying')
    shutil.copyfile(path, staged / 'source-lock.json')
    if file_hash(staged / 'source-lock.json') != pin or file_hash(path) != pin:
        raise ValueError('Provenance changed during preparation')
    (staged / 'NOTICE.md').write_text(
        '# Selected source provenance\n\nSee source-lock.json and metadata/ for data terms and origins.\n'
        'Preparation preserves source text, removes exact duplicates and rejects split conflicts.\n'
        'No blanket model-weight license or redistribution right is assigned.\n', encoding='utf-8')
    return sources, pin


def prepare_documents(config_path, documents, provenance, output, *, progress_callback=None):
    config = load_config(config_path)
    documents = Path(documents)
    input_pin = file_hash(documents)
    with new_directory(output) as staged:
        sources, provenance_pin = copy_provenance(provenance, staged)
        source_ids = {s['id'] for s in sources}
        connection = sqlite3.connect(staged / 'selection.sqlite')
        connection.executescript('CREATE TABLE docs (id TEXT PRIMARY KEY, source TEXT, origin TEXT, '
                                 'grp TEXT, split TEXT, text TEXT); '
                                 'CREATE TABLE groups (source TEXT, grp TEXT, split TEXT, PRIMARY KEY(source,grp)); '
                                 'CREATE TABLE paragraphs (id TEXT PRIMARY KEY, split TEXT);')
        counts, characters = Counter(), Counter()
        seen, last_report = 0, time.monotonic()
        try:
            for row in read_jsonl(documents):
                seen += 1
                if progress_callback and time.monotonic() - last_report >= 10:
                    progress_callback('encode-selection', documents=seen)
                    last_report = time.monotonic()
                if (not isinstance(row, dict) or row.get('source') not in source_ids or row.get('split') not in SPLITS
                        or any(not isinstance(row.get(k), str) or not row[k] for k in ('origin', 'group', 'text'))):
                    raise ValueError('Each document needs source, origin, group, explicit split and text')
                text, split = row['text'], row['split']
                if (len(text) > config['data']['max_document_characters'] or not normalized(text)
                        or any(0xD800 <= ord(c) <= 0xDFFF for c in text)):
                    raise ValueError('Invalid or oversized document')
                key = (row['source'], row['group'])
                previous = connection.execute('SELECT split FROM groups WHERE source=? AND grp=?', key).fetchone()
                if previous and previous[0] != split:
                    raise ValueError('A source/document/template group crosses splits')
                connection.execute('INSERT OR IGNORE INTO groups VALUES (?,?,?)', (*key, split))
                identity = fingerprint(normalized(text))
                previous = connection.execute('SELECT split FROM docs WHERE id=?', (identity,)).fetchone()
                if previous:
                    if previous[0] != split:
                        raise ValueError('Normalized duplicate text crosses splits')
                    counts['duplicate_documents'] += 1
                    continue
                paragraphs = {fingerprint(normalized(line)) for line in text.splitlines() if len(normalized(line)) >= 32}
                if any((p := connection.execute('SELECT split FROM paragraphs WHERE id=?', (key,)).fetchone())
                       and p[0] != split for key in paragraphs):
                    raise ValueError('A long paragraph crosses document splits')
                connection.executemany('INSERT OR IGNORE INTO paragraphs VALUES (?,?)', ((p, split) for p in paragraphs))
                connection.execute('INSERT INTO docs VALUES (?,?,?,?,?,?)',
                                   (identity, row['source'], row['origin'], row['group'], split, text))
                if split == 'train':
                    characters.update(text)
            tokenizer = fit_counts(characters, config['model']['vocab_size'])
            tokenizer.save(staged / 'tokenizer.json')
            splits, source_counts = {}, {}
            for split in SPLITS:
                stats = Counter()
                by_source = {}
                with (staged / f'{split}.tokens.bin').open('wb') as tokens, \
                        (staged / f'{split}.windows.bin').open('wb') as windows, \
                        (staged / f'{split}.documents.jsonl').open('w', encoding='utf-8') as stream:
                    rows = connection.execute('SELECT id,source,origin,grp,text FROM docs WHERE split=? ORDER BY id', (split,))
                    for identity, source, origin, group, text in rows:
                        ids = tokenizer.encode(text)
                        base = stats['tokens']
                        tokens.write(np.asarray(ids, dtype='<u2').tobytes())
                        for start in range(0, len(ids) - 1, config['model']['context']):
                            length = min(config['model']['context'] + 1, len(ids) - start)
                            windows.write(np.asarray([base + start, length], dtype='<u8').tobytes())
                            stats['windows'] += 1
                            stats['targets'] += length - 1
                        stats.update(documents=1, characters=len(text), tokens=len(ids))
                        fallback = sum(ord(c) > 127 and c not in tokenizer.lookup for c in text)
                        non_ascii = sum(ord(c) > 127 for c in text)
                        by_source.setdefault(source, Counter()).update(documents=1, targets=len(ids) - 1,
                            characters=len(text), byte_fallback_scalars=fallback, non_ascii_scalars=non_ascii)
                        stats['byte_fallback_scalars'] += fallback
                        stats['non_ascii_scalars'] += non_ascii
                        stream.write(json.dumps(dict(id=identity, source=source, origin=origin, group=group, text=text),
                                                ensure_ascii=False) + '\n')
                        if progress_callback and time.monotonic() - last_report >= 10:
                            progress_callback('encode-split', split=split, documents=stats['documents'], targets=stats['targets'])
                            last_report = time.monotonic()
                if not stats['windows']:
                    raise ValueError('Every split needs documents; no automatic split reassignment')
                splits[split] = dict(stats)
                source_counts[split] = {source: dict(values) for source, values in by_source.items()}
        finally:
            connection.close()
        (staged / 'selection.sqlite').unlink()
        if file_hash(documents) != input_pin:
            raise ValueError('Documents changed during preparation')
        return finish_manifest(staged, dict(schema_version=1, kind='si-character-lm',
            model_limits={k: config['model'][k] for k in ('vocab_size', 'context')},
            tokenizer_digest=tokenizer.digest, tokenizer_origin='fit-on-training-text', splits=splits,
            sources=sources, document_sha256=input_pin, provenance_sha256=provenance_pin,
            source_counts=source_counts, selection_counts=dict(counts), preparation_code=file_hash(Path(__file__))))


def prepare_pools(config_path, lm_data, records, provenance, output):
    from llm.reranker_small.data import load_bundle
    from .scoring import printable, suffix, validate_pool

    config = load_config(config_path)
    lm_manifest, tokenizer, _ = load_bundle(lm_data, config, ('train',))
    raw_pin = file_hash(records)
    with new_directory(output) as staged:
        _, provenance_pin = copy_provenance(provenance, staged)
        connection = sqlite3.connect(staged / 'documents.sqlite')
        connection.execute('CREATE TABLE docs (id TEXT PRIMARY KEY, split TEXT, text TEXT)')
        connection.execute('CREATE TABLE queries (id TEXT PRIMARY KEY, split TEXT)')
        writers = {s: PoolWriter(staged, s) for s in SPLITS}
        seen, counts = set(), Counter()
        try:
            for split in SPLITS:
                path = checked_file(lm_data, lm_manifest, f'{split}.documents.jsonl')
                for row in read_jsonl(path):
                    connection.execute('INSERT INTO docs VALUES (?,?,?)', (row['id'], split, row['text']))
            for row in read_jsonl(records):
                if (not isinstance(row.get('id'), str) or not row['id'] or row['id'] in seen
                        or not printable(row.get('input'))
                        or 'teacher_scores' in row):
                    raise ValueError('Unscored pools require unique IDs; teacher scores are generated separately')
                seen.add(row['id'])
                parent = connection.execute('SELECT split,text FROM docs WHERE id=?', (row.get('document_id'),)).fetchone()
                if not parent:
                    raise ValueError('Pool document is absent from the frozen LM dataset')
                split, text = parent
                if row.get('split', split) != split:
                    raise ValueError('Pool split conflicts with its source document')
                eligible = validate_pool(row, tokenizer, config)
                if row.get('context', '') + row['observed_text'] not in text:
                    raise ValueError('Context and observed span must be contiguous in their source document')
                if not eligible:
                    counts[f'{split}_unscorable_token_limit'] += 1
                    continue
                effective = suffix(row.get('context', ''), tokenizer, config['scoring']['context_tokens'])
                query = fingerprint([normalized(effective), normalized(row.get('input', '')),
                                     sorted((normalized(c['text']), c['language']) for c in row['candidates'])])
                previous = connection.execute('SELECT split FROM queries WHERE id=?', (query,)).fetchone()
                if previous and previous[0] != split:
                    raise ValueError('An equivalent candidate query crosses splits')
                connection.execute('INSERT OR IGNORE INTO queries VALUES (?,?)', (query, split))
                prepared = {**row, 'context': effective, 'split': split}
                writers[split].append(prepared)
        finally:
            connection.close()
            for writer in writers.values():
                writer.close()
        (staged / 'documents.sqlite').unlink()
        if not all(w.count for w in writers.values()):
            raise ValueError('Each split needs eligible pools; inspect token-limit exclusions')
        if raw_pin != file_hash(records):
            raise ValueError('Pool input changed during preparation')
        return finish_manifest(staged, dict(schema_version=1, kind='si-student-pools',
            lm_dataset_id=lm_manifest['dataset_id'], tokenizer_digest=tokenizer.digest,
            limits={k: config['scoring'][k] for k in ('max_candidates', 'context_tokens', 'candidate_tokens')},
            splits={s: {'pools': w.count} for s, w in writers.items()}, teacher=None,
            exclusions=dict(counts), input_sha256=raw_pin, provenance_sha256=provenance_pin,
            preparation_code=file_hash(Path(__file__))))
