"""Stream verified raw-text-v2 snapshots into an explicitly sampled LM bundle."""

from collections import Counter
from contextlib import ExitStack
import codecs
import hashlib
import json
from pathlib import Path
import re
import shutil
import sqlite3
import time

from corpus.common import new_directory
from llm.pinyin_to_text.common import normalized
from llm.reranker_small.tokenizer import fit_counts
from .prepare import finish_manifest, prepare_documents
from .settings import SPLITS, file_hash, fingerprint, load_config, read_json, write_json

BUNDLES = ('lccc', 'dialogue', 'wikipedia', 'kubernetes', 'tensorflow', 'mdn')
DIALOGUES = ('kdconv', 'crosswoz')
CATEGORIES = {'lccc': 'dialogue', 'kdconv': 'dialogue', 'crosswoz': 'dialogue',
              'wikipedia': 'wikipedia', 'kubernetes': 'technical',
              'tensorflow': 'technical', 'mdn': 'technical'}
UPSTREAM_SPLITS = {'train': 'train', 'dev': 'validation', 'val': 'validation',
                   'validation': 'validation', 'test': 'test'}
SPLIT_PRIORITY = {'train': 0, 'validation': 1, 'test': 2}


def progress(event, **values):
    print(json.dumps(dict(event=event, **values)), flush=True)


def load_mixture(path):
    value = read_json(path)
    if value.get('schema_version') != 1:
        raise ValueError('Expected schema-1 corpus sampling configuration')
    for key in ('train_target_tokens', 'calibration_characters'):
        if type(value[key]) is not int or value[key] <= 0:
            raise ValueError('Positive integer required: ' + key)
    shares = value['shares']
    if (set(shares) != set(CATEGORIES.values()) or any(type(v) not in (float, int) or not 0 < v < 1
                                                     for v in shares.values())
            or abs(sum(shares.values()) - 1) > 1e-9):
        raise ValueError('Positive dialogue/wikipedia/technical shares must sum to one')
    for key in ('validation_fraction', 'test_fraction'):
        if type(value[key]) not in (float, int) or not 0 < value[key] < 1:
            raise ValueError('Invalid split fraction')
    if value['validation_fraction'] + value['test_fraction'] >= 1:
        raise ValueError('Held-out fractions leave no training data')
    return value


def safe_path(root, name):
    root = Path(root).resolve()
    relative = Path(name)
    path = (root / relative).resolve()
    if relative.is_absolute() or '..' in relative.parts or not path.is_relative_to(root):
        raise ValueError('Unsafe corpus provenance path')
    return path


def stamp(path):
    stat = path.stat()
    return stat.st_size, stat.st_mtime_ns, stat.st_ino


class Snapshot:
    def __init__(self, root, name, notices_root, audit, *, directory=None):
        self.root, self.name = Path(directory) if directory is not None else Path(root) / name, name
        self.path = self.root / 'manifest.json'
        self.pin = file_hash(self.path)
        self.manifest = read_json(self.path)
        value = self.manifest
        if (value.get('schema_version') != 2 or value.get('extraction_contract') != 'complete-simplified-text-lines-v2'
                or value.get('source', {}).get('id') != name
                or not {'text.txt', 'documents.jsonl'} <= value['files'].keys()):
            raise ValueError('Expected a complete raw-text-v2 snapshot: ' + name)
        self.files = {}
        for filename, pin in value['files'].items():
            path = safe_path(self.root, filename)
            if (type(pin.get('bytes')) is not int or pin['bytes'] < 0
                    or not re.fullmatch('[0-9a-f]{64}', pin.get('sha256', ''))):
                raise ValueError('Invalid corpus size/checksum declaration: ' + name + '/' + filename)
            actual_size = path.stat().st_size
            if actual_size != pin['bytes']:
                hint = (' Use --dialogue-root to select another complete dialogue snapshot.'
                        if name == 'dialogue' else '')
                raise ValueError(f'Corpus file size mismatch: {path}: declared {pin["bytes"]} bytes, '
                                 f'actual {actual_size}. Text, document metadata and manifest must match.' + hint)
            self.files[filename] = (path, stamp(path), pin['sha256'])
            if filename not in ('text.txt', 'documents.jsonl') and file_hash(path) != pin['sha256']:
                raise ValueError('Corpus attribution checksum mismatch: ' + name + '/' + filename)
        target = audit / 'attribution' / name / 'input-manifest.json'
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.path, target)
        if file_hash(target) != self.pin:
            raise ValueError('Corpus manifest changed while copying')
        self.sources = []
        descriptors = ([(d['id'], d) for d in value['source']['datasets'] if d['id'] in DIALOGUES]
                       if name == 'dialogue' else [(name, value['source'])])
        if name == 'dialogue' and (len(descriptors) != len(DIALOGUES) or {i for i, _ in descriptors} != set(DIALOGUES)):
            raise ValueError('Dialogue snapshot must include KdConv and CrossWOZ')
        for identity, descriptor in descriptors:
            revision, license_name = descriptor.get('revision'), descriptor.get('license')
            if not isinstance(revision, str) or not revision or not isinstance(license_name, str) or not license_name:
                raise ValueError('Selected source lacks revision or data terms: ' + identity)
            self.sources.append(dict(id=identity, origin=descriptor.get('repository', descriptor.get('url', name)),
                                     revision=revision, license=license_name, category=CATEGORIES[identity],
                                     prepared_manifest_sha256=self.pin))
            notices = (descriptor.get('documents', []) if name == 'dialogue' else
                       [descriptor[k] for k in ('license_document', 'dataset_card') if k in descriptor]
                       + descriptor.get('additional_documents', []))
            if not notices:
                raise ValueError('Selected source needs its retained source notices: ' + identity)
            for entry in notices:
                source = (safe_path(self.root, 'attribution/' + entry['path']) if name == 'dialogue'
                          else safe_path(notices_root, entry['path']))
                expected = entry['sha256']
                if file_hash(source) != expected:
                    raise ValueError('Selected source notice checksum mismatch: ' + identity)
                target = audit / 'attribution' / name / entry['path']
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                if file_hash(target) != expected:
                    raise ValueError('Selected source notice changed while copying')

    def verify_unchanged(self):
        if file_hash(self.path) != self.pin or any(stamp(path) != initial for path, initial, _ in self.files.values()):
            raise ValueError('Prepared corpus changed during sampling: ' + self.name)

    def rows(self, maximum):
        """Validate text ranges and hash both complete files, including skipped rows."""
        digests = {name: hashlib.sha256() for name in ('text.txt', 'documents.jsonl')}
        count, next_line, last_report = 0, 1, time.monotonic()
        with ExitStack() as stack:
            text = stack.enter_context(self.files['text.txt'][0].open('rb'))
            metadata = stack.enter_context(self.files['documents.jsonl'][0].open('rb'))
            for raw in metadata:
                digests['documents.jsonl'].update(raw)
                row = json.loads(raw)
                length = row.get('lines')
                if (type(length) is not int or length < 0 or row.get('first_line') != next_line
                        or not isinstance(row.get('origin'), str) or not row['origin']):
                    raise ValueError('Invalid raw-text-v2 document range: ' + self.name)
                selected = self.name != 'dialogue' or row.get('dataset') in DIALOGUES
                parts, size, oversized = [], 0, False
                for _ in range(length):
                    decoder = codecs.getincrementaldecoder('utf-8')() if selected and not oversized else None
                    started = False
                    while True:
                        chunk = text.readline(65536)
                        if not chunk and not started:
                            raise ValueError('Truncated raw-text-v2 document range: ' + self.name)
                        started = True
                        digests['text.txt'].update(chunk)
                        end = chunk.endswith(b'\n') or len(chunk) < 65536
                        if selected and not oversized:
                            decoded = decoder.decode(chunk, final=end)
                            size += len(decoded)
                            oversized = size > maximum
                            if oversized:
                                parts.clear()
                            else:
                                parts.append(decoded)
                        if end:
                            break
                next_line += length
                count += 1
                yield row, ''.join(parts) if selected and not oversized else None, oversized
                if time.monotonic() - last_report >= 10:
                    progress('read-progress', source=self.name, records=count)
                    last_report = time.monotonic()
            if text.read(1):
                raise ValueError('Unreferenced text after corpus metadata: ' + self.name)
        for name, digest in digests.items():
            if digest.hexdigest() != self.files[name][2]:
                raise ValueError('Corpus checksum mismatch: ' + self.name + '/' + name)
        if count != self.manifest['counts']['documents']:
            raise ValueError('Corpus metadata document count mismatch: ' + self.name)
        self.verify_unchanged()
        progress('read-complete', source=self.name, records=count)


def group_key(bundle, row):
    if bundle == 'lccc':
        match = re.fullmatch(r'(row:\d+)/turn:(\d+)', row['origin'])
        if not match:
            raise ValueError('Invalid LCCC conversation/turn origin')
        return 'lccc', match[1], None, int(match[2])
    if bundle == 'dialogue':
        identity = row.get('dataset')
        if identity not in DIALOGUES:
            return None
        if (row.get('split') not in UPSTREAM_SPLITS or row.get('conversation') is None
                or not isinstance(row.get('path'), str) or type(row.get('turn')) is not int):
            raise ValueError('Invalid selected conversation metadata')
        return identity, f'{row["path"]}/conversation:{row["conversation"]}', UPSTREAM_SPLITS[row['split']], row['turn']
    group = row['origin'].split('&oldid=', 1)[0] if bundle == 'wikipedia' else row['origin']
    return bundle, group, None, None


def assigned_split(seed, source, group, mixture):
    fraction = int(fingerprint([seed, 'split', source, group])[:16], 16) / 2**64
    if fraction < mixture['test_fraction']:
        return 'test'
    if fraction < mixture['test_fraction'] + mixture['validation_fraction']:
        return 'validation'
    return 'train'


def ingest(connection, snapshot, seed, mixture, maximum, counts):
    current, parts, size, oversized, last_turn, origin = None, [], 0, False, None, None

    def flush():
        if current is None:
            return
        source, group, upstream = current
        try:
            connection.execute('INSERT INTO groups VALUES (?,?)', (source, group))
        except sqlite3.IntegrityError as error:
            raise ValueError('A conversation/page group reappears noncontiguously or with conflicting splits') from error
        if oversized:
            counts['oversized_groups'] += 1
            return
        text = ''.join(parts)
        canonical = normalized(text)
        if not canonical:
            counts['empty_groups'] += 1
            return
        split = upstream or assigned_split(seed, source, group, mixture)
        identity = fingerprint(canonical)
        previous = connection.execute('SELECT split FROM docs WHERE id=?', (identity,)).fetchone()
        if previous:
            counts['duplicate_groups'] += 1
            if SPLIT_PRIORITY[previous[0]] >= SPLIT_PRIORITY[split]:
                return
            connection.execute('DELETE FROM docs WHERE id=?', (identity,))
            counts['groups_retained_before_sampling'] -= 1
            counts['training_or_validation_duplicate_removed_for_heldout'] += 1
        priority = fingerprint([seed, 'sample', source, group])
        connection.execute('INSERT INTO docs VALUES (?,?,?,?,?,?,?,?,?)',
                           (identity, source, group, split, CATEGORIES[source], priority, origin, text, upstream))
        counts['groups_retained_before_sampling'] += 1

    for row, text, too_long in snapshot.rows(maximum):
        key = group_key(snapshot.name, row)
        if key is None:
            flush()
            current, parts = None, []
            counts['excluded_' + str(row.get('dataset', 'unknown')) + '_turns'] += 1
            continue
        source, group, upstream, turn = key
        if current != (source, group, upstream):
            flush()
            current, parts, size, oversized, last_turn, origin = (source, group, upstream), [], 0, False, None, row['origin']
        if turn is not None and last_turn is not None and turn <= last_turn:
            raise ValueError('Conversation turns are not in original ascending order')
        last_turn = turn
        oversized = oversized or too_long
        if not oversized:
            size += len(text)
            oversized = size > maximum
            if not oversized:
                parts.append(text)
        if oversized:
            parts.clear()
    flush()


def target_tokens(text, tokenizer):
    # Equivalent to len(tokenizer.encode(text)) - 1; avoids a large token list.
    return 1 + sum(1 if c in tokenizer.lookup else len(c.encode('utf-8')) for c in text)


def ordered_rows(connection, category, split):
    return connection.execute('SELECT id,source,grp,origin,text,upstream FROM docs WHERE category=? AND split=? '
                              'ORDER BY priority,source,grp', (category, split))


def select_documents(connection, config, mixture, audit, allow_shortfall, counts):
    characters = Counter()
    calibration = {}
    for category, share in mixture['shares'].items():
        used = 0
        for _, _, _, _, text, _ in ordered_rows(connection, category, 'train'):
            characters.update(text)
            used += len(text)
            if used >= mixture['calibration_characters'] * share:
                break
        calibration[category] = used
    tokenizer = fit_counts(characters, config['model']['vocab_size'])
    tokenizer.save(audit / 'sampling-tokenizer.json')
    fractions = dict(train=1 - mixture['test_fraction'] - mixture['validation_fraction'],
                     validation=mixture['validation_fraction'], test=mixture['test_fraction'])
    connection.execute('CREATE TABLE selected_paragraphs (id TEXT PRIMARY KEY, split TEXT)')
    selection, selected_sources = {}, Counter()
    with (audit / 'documents.jsonl').open('w', encoding='utf-8') as output:
        # Held-out paragraphs take priority; whole conflicting groups are excluded.
        for split in ('test', 'validation', 'train'):
            selection[split] = {}
            for category, share in mixture['shares'].items():
                budget = max(1, round(mixture['train_target_tokens'] * fractions[split] / fractions['train'] * share))
                tokens, documents = 0, 0
                for identity, source, group, origin, text, upstream in ordered_rows(connection, category, split):
                    paragraphs = {fingerprint(normalized(line)) for line in text.splitlines() if len(normalized(line)) >= 32}
                    if any((p := connection.execute('SELECT split FROM selected_paragraphs WHERE id=?', (key,)).fetchone())
                           and p[0] != split for key in paragraphs):
                        counts[f'{split}_cross_split_paragraph_groups_excluded'] += 1
                        continue
                    connection.executemany('INSERT OR IGNORE INTO selected_paragraphs VALUES (?,?)',
                                           ((key, split) for key in paragraphs))
                    record = dict(source=source, origin=origin, group=group, split=split, text=text,
                                  upstream_split=upstream, corpus_document_id=identity)
                    output.write(json.dumps(record, ensure_ascii=False) + '\n')
                    tokens += target_tokens(text, tokenizer)
                    documents += 1
                    selected_sources[source] += 1
                    if tokens >= budget:
                        break
                selection[split][category] = dict(requested_targets=budget, estimated_targets=tokens,
                                                  documents=documents, shortfall=max(0, budget - tokens))
                progress('sampled', split=split, category=category, **selection[split][category])
                if tokens < budget and not allow_shortfall:
                    raise ValueError(f'Insufficient {split}/{category} tokens: {tokens} < {budget}; '
                                     'reduce --train-tokens or explicitly use --allow-shortfall')
    return dict(calibration_train_characters=calibration, sampling_tokenizer_digest=tokenizer.digest,
                selection=selection, selected_source_groups=dict(selected_sources), counts=dict(counts))


def prepare_corpus(config_path, mixture_path, prepared_root, notices_root, output, *,
                   train_tokens=None, allow_shortfall=False, dialogue_root=None):
    config, mixture = load_config(config_path), load_mixture(mixture_path)
    if config['stage'] != 'pretrain':
        raise ValueError('Corpus preparation needs a pretraining configuration')
    if train_tokens is not None:
        if type(train_tokens) is not int or train_tokens <= 0:
            raise ValueError('--train-tokens must be positive')
        mixture['train_target_tokens'] = train_tokens
    with new_directory(output) as staged:
        audit = staged / 'import'
        audit.mkdir()
        snapshots = [Snapshot(prepared_root, name, notices_root, audit,
                              directory=dialogue_root if name == 'dialogue' else None) for name in BUNDLES]
        connection = sqlite3.connect(staged / 'sampling.sqlite')
        # Only this disposable scratch database uses relaxed durability.
        connection.executescript('PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; '
            'CREATE TABLE groups (source TEXT, grp TEXT, PRIMARY KEY(source,grp)); '
            'CREATE TABLE docs (id TEXT PRIMARY KEY,source TEXT,grp TEXT,split TEXT,category TEXT,'
            'priority TEXT,origin TEXT,text TEXT,upstream TEXT);')
        counts = Counter()
        try:
            for snapshot in snapshots:
                progress('read-start', source=snapshot.name)
                ingest(connection, snapshot, config['seed'], mixture, config['data']['max_document_characters'], counts)
                connection.commit()
            progress('indexing-groups')
            connection.execute('CREATE INDEX sampling_order ON docs(category,split,priority,source,grp)')
            report = select_documents(connection, config, mixture, audit, allow_shortfall, counts)
        finally:
            connection.close()
        (staged / 'sampling.sqlite').unlink()
        attribution = {str(p.relative_to(audit)): file_hash(p) for p in sorted((audit / 'attribution').rglob('*')) if p.is_file()}
        sources = [source for snapshot in snapshots for source in snapshot.sources
                   if source['id'] in report['selected_source_groups']]
        write_json(audit / 'provenance.json', dict(schema_version=1, sources=sources, files=attribution))
        write_json(audit / 'mixture.json', mixture)
        progress('encode-start')
        manifest = prepare_documents(config_path, audit / 'documents.jsonl', audit / 'provenance.json',
                                     staged / 'encoded', progress_callback=progress)
        for path in (staged / 'encoded').iterdir():
            path.rename(staged / path.name)
        (staged / 'encoded').rmdir()
        report['actual'] = {}
        for split in SPLITS:
            by_category = Counter()
            for source, stats in manifest['source_counts'][split].items():
                by_category[CATEGORIES[source]] += stats['targets']
            total = sum(by_category.values())
            report['actual'][split] = dict(targets=total, by_category=dict(by_category),
                requested_targets={category: report['selection'][split][category]['requested_targets']
                                   for category in mixture['shares']},
                shares={category: by_category[category] / total for category in mixture['shares']})
        report['note'] = ('Quotas use a provisional train-only calibration tokenizer and whole groups. '
                          'Final vocabulary is fitted again on selected training documents only; '
                          'actual final-token shares above are authoritative, not the quota estimates.')
        write_json(staged / 'sampling-report.json', report)
        for snapshot in snapshots:
            snapshot.verify_unchanged()
        manifest.pop('dataset_id')
        manifest.pop('files')
        manifest['corpus_sampling'] = dict(mixture=mixture, allow_shortfall=allow_shortfall,
            seed=config['seed'], maximum_document_characters=config['data']['max_document_characters'],
            prepared_manifest_hashes={s.name: s.pin for s in snapshots},
            sampling_code=file_hash(Path(__file__)), report='sampling-report.json')
        manifest = finish_manifest(staged, manifest)
        progress('complete', dataset_id=manifest['dataset_id'], training_targets=manifest['splits']['train']['targets'])
        return manifest
