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
from corpus.prepare import documents
from corpus.clean.chinese import HAN
from llm.pinyin_to_text.common import normalized
from .settings import ROOT, REPO, SPLITS, file_hash, fingerprint, load_config, write_json
from .tokenizer import fit_counts


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


def _select(connection, source, archive, config, converter, train_counts):
    counts = Counter()
    last_report = time.monotonic()
    stream = documents(source, archive, counts, preserve_lccc_spacing=True, include_title=True)
    try:
        for origin, raw in stream:
            counts["documents_seen"] += 1
            if len(raw) > config["data"]["max_document_characters"]:
                counts["oversized_documents"] += 1
                continue
            text = clean_document(raw, converter)
            if sum(len(match.group()) for match in HAN.finditer(text)) < config["data"]["minimum_han_characters"]:
                counts["insufficient_han"] += 1
                continue
            canonical = normalized(text)
            identity = hashlib.sha256(canonical.encode()).hexdigest()
            existing = connection.execute('SELECT canonical FROM docs WHERE id=?', (identity,)).fetchone()
            if existing:
                if existing[0] != canonical:
                    raise ValueError("Document digest collision")
                counts["duplicate_documents"] += 1
                continue
            group = document_group(source, origin)
            split = split_for(source["id"], group, config)
            # Keep a document whole. Reject it if a substantial exact paragraph
            # is already in another split; never move its other paragraphs around.
            paragraphs = {normalized(line) for line in text.splitlines() if len(normalized(line)) >= 32}
            if any((row := connection.execute('SELECT split FROM paragraphs WHERE text=?', (line,)).fetchone())
                   and row[0] != split for line in paragraphs):
                counts["cross_split_paragraph_documents"] += 1
                continue
            connection.execute('INSERT INTO docs (id, canonical, source, origin, grp, split, text) VALUES (?,?,?,?,?,?,?)',
                               (identity, canonical, source["id"], origin, group, split, text))
            connection.executemany('INSERT OR IGNORE INTO paragraphs VALUES (?,?)', ((line, split) for line in paragraphs))
            if split == "train":
                train_counts.update(text)
            counts["documents_kept"] += 1
            counts["characters_kept"] += len(text)
            if time.monotonic() - last_report >= 30:
                print(json.dumps({"event": "prepare_progress", "source": source["id"], "counts": dict(counts)}), flush=True)
                last_report = time.monotonic()
            limit = config["data"]["max_characters_per_source"]
            if limit and counts["characters_kept"] >= limit:
                counts["stopped_at_character_limit"] = 1
                break
    finally:
        stream.close()
    print(json.dumps({"event": "source_complete", "source": source["id"], "counts": dict(counts)}), flush=True)
    return dict(counts)


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


def prepare(config_path, output, source_lock=LOCK, raw_root=CHINESE / 'raw'):
    config = load_config(config_path)
    source_lock = Path(source_lock)
    selected = {source['id']: source for source in load_sources(source_lock, source_lock.parent)}
    if set(config["data"]["sources"]) - selected.keys():
        raise ValueError("Configured corpus source is absent from the source lock")
    sources = [selected[name] for name in config["data"]["sources"]]
    from opencc import OpenCC
    converter = OpenCC('t2s')
    with new_directory(output) as staged:
        archives = [(source, verified_archive(source, raw_root)) for source in sources]
        connection = sqlite3.connect(staged / 'selection.sqlite')
        try:
            connection.execute('CREATE TABLE docs (ordinal INTEGER PRIMARY KEY, id TEXT UNIQUE, canonical TEXT, '
                               'source TEXT, origin TEXT, grp TEXT, split TEXT, text TEXT)')
            connection.execute('CREATE TABLE paragraphs (text TEXT PRIMARY KEY, split TEXT) WITHOUT ROWID')
            train_counts = Counter()
            source_counts = {source['id']: _select(connection, source, archive, config, converter, train_counts)
                             for source, archive in archives}
            tokenizer = fit_counts(train_counts, config['model']['vocab_size'])
            tokenizer.save(staged / 'tokenizer.json')
            split_counts = {split: _pack(connection, tokenizer, config['model']['context'], staged, split)
                            for split in SPLITS}
        finally:
            connection.close()
        (staged / 'selection.sqlite').unlink()
        used = [source for source in sources if source_counts[source['id']].get('documents_kept')]
        for source in used:
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
            'tokenizer_digest': tokenizer.digest,
            'code': {str(path.relative_to(REPO)): file_hash(path) for path in
                     [ROOT / 'prepare.py', ROOT / 'tokenizer.py', ROOT / 'settings.py',
                      REPO / 'corpus/prepare.py', REPO / 'corpus/common.py',
                      REPO / 'corpus/clean/chinese.py', REPO / 'corpus/clean/wikipedia.py']},
            'files': {str(path.relative_to(staged)): file_hash(path)
                      for path in sorted(staged.rglob('*')) if path.is_file()},
            'notes': 'Whole cleaned documents retained. Windows never cross documents; vocabulary fits train only. '
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
    args = parser.parse_args()
    result = prepare(args.config, args.output, args.source_lock, args.raw_root)
    print(json.dumps({'dataset_id': result['dataset_id'], 'splits': result['splits']}, indent=2))
