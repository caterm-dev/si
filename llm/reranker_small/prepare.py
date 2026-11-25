"""Freeze whole documents, document-level splits and train-only LM token arrays."""

import argparse
from collections import Counter
import hashlib
import importlib.metadata
import json
from pathlib import Path
import re
import shutil
import sqlite3
import time
import unicodedata

import numpy as np

from corpus.common import CHINESE, LOCK, new_directory, load_sources, verified_archive
from corpus.readers import documents
from corpus.clean.chinese import HAN
from llm.pinyin_to_text.common import normalized, read_jsonl
from .dialogue_data import COLLECTIONS, copy_prepared_attribution, prepared_documents, prepared_source
from .settings import ROOT, REPO, SPLITS, file_hash, fingerprint, load_config, read_json, write_json
from .tokenizer import Tokenizer, fit_counts


def document_group(source, origin):
    if source["kind"] == "lccc":
        return origin.split("/turn:")[0]
    if source["kind"] == "wikipedia":
        return origin.split("&oldid=")[0]
    return origin


def split_for(source_id, group, config):
    key = f'{config["seed"]}:{source_id}:{group}'.encode()
    fraction = int.from_bytes(hashlib.sha256(key).digest()[:8], "big") / 2**64
    data = config["data"]
    if fraction < data["test_fraction"]:
        return "test"
    if fraction < data["test_fraction"] + data["validation_fraction"]:
        return "validation"
    return "train"


def clean_document(text, converter):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Preserve punctuation, paragraph breaks, digits and English word spaces.
    # Other C0 controls are boundaries, never hidden model inputs.
    text = ''.join(c if c in '\n\t' or unicodedata.category(c) not in ('Cc', 'Cs') else ' ' for c in text)
    text = re.sub(r'(?m)^\s{0,3}#{1,6}\s+', '', text)
    return converter.convert(text).strip()


def _select(connection, source, archive, config, converter, train_counts, tokenizer, parent_splits):
    counts = Counter()
    subsources = {}
    last_report = time.monotonic()
    quota = config["data"].get("train_target_quotas", {}).get(source["id"])
    subquotas = quota if isinstance(quota, dict) else {}
    exclude_parent = config['data'].get('exclude_parent_documents', False)
    skip = config["data"].get("skip_lccc_records", 0) if source["id"] == "lccc" else 0
    prepared = source['kind'] == 'prepared-dialogue'
    stream = (prepared_documents(archive, counts) if prepared else
              documents(source, archive, counts, preserve_lccc_spacing=True, include_title=True))
    try:
        for record in stream:
            if skip and counts["records_read"] <= skip:
                continue
            if prepared:
                origin, raw, (dataset, group, upstream_split) = record
                subcounts = subsources.setdefault(dataset, Counter())
                subquota = subquotas.get(dataset, 0)
                if quota and upstream_split not in ('validation', 'test') and subcounts['train_targets'] >= subquota:
                    continue
                split = upstream_split or split_for(source['id'], group, config)
            else:
                origin, raw = record
                group = document_group(source, origin)
                split = split_for(source["id"], group, config)
            counts["documents_seen"] += 1
            if exclude_parent and connection.execute(
                    'SELECT 1 FROM parent_groups WHERE source=? AND grp=?', (source['id'], group)).fetchone():
                counts['excluded_parent_group_documents'] += 1
                continue
            if len(raw) > config["data"]["max_document_characters"]:
                counts["oversized_documents"] += 1
                continue
            text = clean_document(raw, converter)
            if sum(len(match.group()) for match in HAN.finditer(text)) < config["data"]["minimum_han_characters"]:
                counts["insufficient_han"] += 1
                continue
            canonical = normalized(text)
            digest = hashlib.sha256(canonical.encode()).digest()
            identity = digest.hex()
            if exclude_parent and connection.execute(
                    'SELECT 1 FROM parent_documents WHERE digest=?', (digest,)).fetchone():
                counts['excluded_parent_documents'] += 1
                continue
            previous_split = parent_splits.get(digest)
            if previous_split is not None and previous_split != split:
                counts["cross_parent_split_documents"] += 1
                continue
            existing = connection.execute('SELECT canonical FROM docs WHERE id=?', (identity,)).fetchone()
            if existing:
                if existing[0] != canonical:
                    raise ValueError("Document digest collision")
                counts["duplicate_documents"] += 1
                continue
            # Keep a document whole. Reject it if a substantial exact paragraph
            # is already in another split; never move its other paragraphs around.
            paragraphs = {normalized(line) for line in text.splitlines() if len(normalized(line)) >= 32}
            if exclude_parent and any(connection.execute(
                    'SELECT 1 FROM parent_paragraphs WHERE digest=?',
                    (hashlib.sha256(line.encode()).digest(),)).fetchone() for line in paragraphs):
                counts['excluded_parent_paragraph_documents'] += 1
                continue
            if any((row := connection.execute('SELECT split FROM paragraphs WHERE text=?', (line,)).fetchone())
                   and row[0] != split for line in paragraphs):
                counts["cross_split_paragraph_documents"] += 1
                continue
            connection.execute('INSERT INTO docs (id, canonical, source, origin, grp, split, text) VALUES (?,?,?,?,?,?,?)',
                               (identity, canonical, source["id"], origin, group, split, text))
            connection.executemany('INSERT OR IGNORE INTO paragraphs VALUES (?,?)', ((line, split) for line in paragraphs))
            if split == "train" and tokenizer is None:
                train_counts.update(text)
            if split == "train" and tokenizer is not None:
                targets = len(tokenizer.encode(text)) - 1
                counts["train_targets"] += targets
                if prepared:
                    subcounts["train_targets"] += targets
            if prepared:
                subcounts[f'{split}_documents'] += 1
            counts["documents_kept"] += 1
            counts["characters_kept"] += len(text)
            if time.monotonic() - last_report >= 30:
                print(json.dumps({"event": "prepare_progress", "source": source["id"], "counts": dict(counts)}), flush=True)
                last_report = time.monotonic()
            limit = config["data"]["max_characters_per_source"]
            if not prepared and quota and counts["train_targets"] >= quota:
                break
            if limit and counts["characters_kept"] >= limit:
                counts["stopped_at_character_limit"] = 1
                break
    finally:
        stream.close()
    if subquotas:
        for dataset, limit in subquotas.items():
            kept = subsources.get(dataset, {}).get('train_targets', 0)
            if kept < limit:
                raise ValueError(f'{source["id"]}/{dataset}: retained {kept:,} of {limit:,} training targets')
    elif quota and counts["train_targets"] < quota:
        raise ValueError(f'{source["id"]}: retained {counts["train_targets"]:,} of {quota:,} training targets')
    result = dict(counts)
    if prepared:
        result['subsources'] = {name: dict(values) for name, values in subsources.items() if values}
    print(json.dumps({"event": "source_complete", "source": source["id"], "counts": result}), flush=True)
    return result


def _pack(connection, tokenizer, context, staged, split):
    stats = Counter()
    with (staged / f'{split}.tokens.bin').open('wb') as tokens, \
            (staged / f'{split}.windows.bin').open('wb') as windows, \
            (staged / f'{split}.documents.jsonl').open('w', encoding='utf-8', newline='\n') as text_file:
        rows = connection.execute('SELECT id, source, origin, grp, text FROM docs WHERE split=? ORDER BY ordinal', (split,))
        for identity, source, origin, group, text in rows:
            ids = tokenizer.encode(text)
            base = stats["tokens"]
            tokens.write(np.asarray(ids, dtype='<u2').tobytes())
            for start in range(0, len(ids) - 1, context):
                length = min(context + 1, len(ids) - start)
                windows.write(np.asarray([base + start, length], dtype='<u8').tobytes())
                stats["windows"] += 1
                stats["targets"] += length - 1
            record = {"id": identity, "source": source, "origin": origin, "group": group, "text": text}
            text_file.write(json.dumps(record, ensure_ascii=False) + '\n')
            stats["documents"] += 1
            stats["characters"] += len(text)
            stats["tokens"] += len(ids)
    if not stats["windows"]:
        raise ValueError(f'No {split} windows; select more documents or review the document split fractions')
    return dict(stats)


def _load_parent_data(path, config, history=None):
    path = Path(path)
    manifest = read_json(path / 'manifest.json')
    if (manifest.get('schema_version') != 1 or manifest.get('kind') != 'si-character-lm'
            or fingerprint({key: value for key, value in manifest.items() if key != 'dataset_id'}) != manifest['dataset_id']):
        raise ValueError('Invalid parent dataset identity')
    if file_hash(path / 'tokenizer.json') != manifest['files']['tokenizer.json']:
        raise ValueError('Parent tokenizer file modified')
    tokenizer = Tokenizer.load(path / 'tokenizer.json')
    if tokenizer.vocab_size != config['model']['vocab_size'] or tokenizer.digest != manifest['tokenizer_digest']:
        raise ValueError('Parent tokenizer differs from the model or dataset manifest')

    identities = {}
    for split in SPLITS:
        name = f'{split}.documents.jsonl'
        if file_hash(path / name) != manifest['files'][name]:
            raise ValueError('Parent document file modified: ' + name)
        for row in read_jsonl(path / name):
            digest = bytes.fromhex(row['id'])
            if history is None:
                identities[digest] = split
            else:
                history.execute('INSERT OR IGNORE INTO parent_documents VALUES (?)', (digest,))
                history.execute('INSERT OR IGNORE INTO parent_groups VALUES (?, ?)', (row['source'], row['group']))
                paragraphs = {normalized(line) for line in row['text'].splitlines() if len(normalized(line)) >= 32}
                history.executemany('INSERT OR IGNORE INTO parent_paragraphs VALUES (?)',
                                    ((hashlib.sha256(line.encode()).digest(),) for line in paragraphs))
    return manifest['dataset_id'], tokenizer, identities


def prepare(config_path, output, source_lock=LOCK, raw_root=CHINESE / 'raw', parent_data=None,
            prepared_root=CHINESE / 'prepared/si-corpus', ancestor_data=()):
    config = load_config(config_path)
    if config['data'].get('train_target_quotas') and parent_data is None:
        raise ValueError('Training target quotas require --parent-data')
    if config['data'].get('exclude_parent_documents') and parent_data is None:
        raise ValueError('Excluding previously used documents requires --parent-data')
    source_lock = Path(source_lock)
    selected = {source['id']: source for source in load_sources(source_lock, source_lock.parent)}
    source_ids = config["data"]["sources"]
    if set(source_ids) - selected.keys() - COLLECTIONS.keys():
        raise ValueError("Configured corpus source is absent from the source lock")
    quotas = config['data'].get('train_target_quotas', {})
    for name in source_ids:
        if quotas and (name in COLLECTIONS) != isinstance(quotas.get(name), dict):
            raise ValueError('Prepared dialogue sources require per-subcorpus training quotas: ' + name)
    from opencc import OpenCC
    converter = OpenCC('t2s')
    with new_directory(output) as staged:
        connection = sqlite3.connect(staged / 'selection.sqlite')
        try:
            history = connection if config['data'].get('exclude_parent_documents') else None
            if history is not None:
                history.execute('CREATE TABLE parent_documents (digest BLOB PRIMARY KEY) WITHOUT ROWID')
                history.execute('CREATE TABLE parent_groups (source TEXT, grp TEXT, PRIMARY KEY(source, grp)) WITHOUT ROWID')
                history.execute('CREATE TABLE parent_paragraphs (digest BLOB PRIMARY KEY) WITHOUT ROWID')
            parent_id, tokenizer, parent_splits = ((None, None, {}) if parent_data is None else
                                                  _load_parent_data(parent_data, config, history))
            ancestor_ids = []
            for ancestor in ancestor_data:
                ancestor_id, ancestor_tokenizer, ancestor_splits = _load_parent_data(ancestor, config, history)
                if tokenizer is None or ancestor_tokenizer.digest != tokenizer.digest:
                    raise ValueError('Ancestor data requires the same frozen parent tokenizer')
                ancestor_ids.append(ancestor_id)
                for identity, split in ancestor_splits.items():
                    previous = parent_splits.get(identity, split)
                    parent_splits[identity] = split if previous == split else 'conflicting-ancestor-splits'
            sources = [prepared_source(prepared_root, name) if name in COLLECTIONS else
                       (selected[name], verified_archive(selected[name], raw_root)) for name in source_ids]
            connection.execute('CREATE TABLE docs (ordinal INTEGER PRIMARY KEY, id TEXT UNIQUE, canonical TEXT, '
                               'source TEXT, origin TEXT, grp TEXT, split TEXT, text TEXT)')
            connection.execute('CREATE TABLE paragraphs (text TEXT PRIMARY KEY, split TEXT) WITHOUT ROWID')
            train_counts = Counter()
            source_counts = {source['id']: _select(connection, source, archive, config, converter, train_counts,
                                                   tokenizer, parent_splits)
                             for source, archive in sources}
            tokenizer_origin = 'frozen' if tokenizer is not None else 'fit-on-training-text'
            tokenizer = tokenizer or fit_counts(train_counts, config['model']['vocab_size'])
            tokenizer.save(staged / 'tokenizer.json')
            split_counts = {split: _pack(connection, tokenizer, config['model']['context'], staged, split)
                            for split in SPLITS}
        finally:
            connection.close()
        (staged / 'selection.sqlite').unlink()
        used = []
        for source, archive in sources:
            if not source_counts[source['id']].get('documents_kept'):
                continue
            used.append(source)
            if source['kind'] == 'prepared-dialogue':
                copy_prepared_attribution(source, archive, staged)
                continue
            records = [source[key] for key in ('license_document', 'dataset_card') if key in source]
            for document in records + source.get('additional_documents', []):
                target = staged / document['path']
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_lock.parent / document['path'], target)
        lines = ['# Actual corpus sources selected for this dataset', '',
                 'The source-lock.json and manifest.json list the sources actually retained.',
                 'Full source license/card documents are copied beside this notice.', '',
                 'Modifications: markup/code removal, OpenCC t2s conversion, control-character',
                 'replacement, exact-document deduplication and cross-split long-paragraph filtering.',
                 'Punctuation, English word spaces and paragraph boundaries remain in document text.',
                 'Original source rights and any ShareAlike conditions remain applicable.', '',
                 'This dataset does not assign a blanket license to future trained weights.', '']
        for source in used:
            lines.append(f'- {source["id"]}: {source.get("name", source["id"])}, {source.get("license", "see source documents")}; '
                         f'{source.get("repository", source.get("origin", "see source-lock.json"))}; revision {source["revision"]}.')
        (staged / 'NOTICE.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
        write_json(staged / 'source-lock.json', {'schema_version': 1, 'language': 'zh-Hans', 'sources': used})
        manifest = {
            'schema_version': 1, 'kind': 'si-character-lm',
            'model_limits': {key: config['model'][key] for key in ('vocab_size', 'context')},
            'selection': {'seed': config['seed'], **config['data']},
            'normalization': {'opencc': importlib.metadata.version('opencc-python-reimplemented'), 'config': 't2s',
                              'paragraph_overlap_minimum': 32},
            'sources': used, 'source_counts': source_counts, 'splits': split_counts,
            'tokenizer_origin': tokenizer_origin,
            'parent_dataset_id': parent_id,
            'ancestor_dataset_ids': ancestor_ids,
            'tokenizer_digest': tokenizer.digest,
            'code': {str(path.relative_to(REPO)): file_hash(path) for path in
                     [ROOT / 'prepare.py', ROOT / 'tokenizer.py', ROOT / 'settings.py', ROOT / 'dialogue_data.py',
                      REPO / 'corpus/readers.py', REPO / 'corpus/common.py',
                      REPO / 'corpus/clean/chinese.py', REPO / 'corpus/clean/wikipedia.py']},
            'files': {str(path.relative_to(staged)): file_hash(path)
                      for path in sorted(staged.rglob('*')) if path.is_file()},
            'notes': 'Whole cleaned documents retained. Windows never cross documents. '
                     'Exact long-paragraph filtering does not detect semantic duplicates or all benchmark overlap.',
        }
        manifest['dataset_id'] = fingerprint(manifest)
        write_json(staged / 'manifest.json', manifest)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'configs/small.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-lock', type=Path, default=LOCK)
    parser.add_argument('--raw-root', type=Path, default=CHINESE / 'raw')
    parser.add_argument('--parent-data', type=Path, help='Reuse the parent tokenizer and keep exact documents in their original splits')
    parser.add_argument('--ancestor-data', type=Path, action='append', default=[],
                        help='Also preserve exact split boundaries from an earlier training dataset')
    parser.add_argument('--prepared-root', type=Path, default=CHINESE / 'prepared/si-corpus',
                        help='Directory containing the verified dialogue and chinese-corpus extracts')
    args = parser.parse_args()
    result = prepare(args.config, args.output, args.source_lock, args.raw_root, args.parent_data, args.prepared_root,
                     args.ancestor_data)
    print(json.dumps({'dataset_id': result['dataset_id'], 'splits': result['splits']}, indent=2))
