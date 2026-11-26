"""Freeze local source metadata or explicitly generate production-bounded pools.

Kept below scripts/ so adding this producer does not change pretraining's
existing Python code identity. No checkpoint, training or teacher is opened.
"""

import argparse
from collections import Counter
import csv
import fcntl
from functools import lru_cache
import json
import math
from pathlib import Path
import random
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import unicodedata

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

from corpus.common import new_directory
from llm.pinyin_to_text.common import file_hash, fingerprint, normalized, read_json, read_jsonl, write_json
from llm.reranker_small.tokenizer import Tokenizer
from llm.reranker_large.data import PoolWriter, checked_file, manifest_at
from llm.reranker_large.prepare import finish_manifest
from llm.reranker_large.settings import ROOT, SPLITS, code_identity, load_config

CHUNKS = re.compile(r'[\u3400-\u9fffA-Za-z0-9]+')
HAN = re.compile(r'[\u3400-\u9fff]')
READING = re.compile(r"[a-zvü]+(?:'[a-zvü]+)*")


def progress(stage, **counts):
    print(json.dumps(dict(stage=stage, **counts), ensure_ascii=False), flush=True)


def secure_file(root, name):
    path = (Path(root) / name).resolve()
    if Path(name).is_absolute() or not path.is_relative_to(Path(root).resolve()) or not path.is_file():
        raise ValueError('Unsafe or missing source file: ' + name)
    return path


def si_files(root, excluded):
    # Only explicit conversation roots; never recursively import scripts/memory/scenes.
    return sorted(p for folder in ('dialogues', 'workbuddy') for p in (root / folder).rglob('*.txt')
                  if not any(part.startswith('.') for part in p.relative_to(root).parts)
                  and 'scripts' not in p.relative_to(root).parts
                  and p.relative_to(root).as_posix() not in excluded)


def pin(path):
    before = path.stat()
    value = dict(bytes=before.st_size, sha256=file_hash(path))
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError('Source changed while hashing: ' + str(path))
    return value


def rules_at(path):
    rules = read_json(path)
    if rules.get('schema_version') != 1:
        raise ValueError('Unsupported sampling rules')
    for values in (rules['source_shares'], rules['input_shares'], rules['si_split_shares'],
                   {k: v['share'] for k, v in rules['context_buckets'].items()},
                   {k: v['share'] for k, v in rules['target_buckets'].items()}):
        if any(not math.isfinite(v) or v <= 0 for v in values.values()) or not math.isclose(sum(values.values()), 1):
            raise ValueError('Sampling shares must be positive and sum to one')
    if set(rules['pools']) != set(SPLITS) or set(rules['si_split_shares']) != set(SPLITS):
        raise ValueError('Explicit train/validation/test counts and shares required')
    if any(type(v) is not int or v <= 0 for v in rules['pools'].values()):
        raise ValueError('Pool counts must be positive integers')
    if type(rules['proposals_per_document']) is not int or rules['proposals_per_document'] <= 0:
        raise ValueError('Positive proposal budget required')
    if not 0 < rules['max_si_file_share'] <= 1:
        raise ValueError('Invalid SI file cap')
    for kind, field in (('context_buckets', 'tokens'), ('target_buckets', 'characters')):
        for value in rules[kind].values():
            lo, hi = value[field]
            if type(lo) is not int or type(hi) is not int or not 0 <= lo <= hi <= 16:
                raise ValueError('Invalid context/target bucket')
    if set(rules['input_shares']) - {'complete', 'partial', 'early', 'typo'}:
        raise ValueError('Unknown input variant')
    return rules


def freeze_sources(si_root, rules_path, output):
    rules = rules_at(rules_path)
    entries = []
    for path in si_files(si_root, rules['excluded_si_files']):
        name = path.relative_to(si_root).as_posix()
        entries.append(dict(path=name, source='si_' + name.split('/')[0], **pin(path)))
    if not entries:
        raise ValueError('No SI conversation files')
    value = dict(schema_version=1, kind='si-distillation-source-lock', files=entries,
        exclusions=rules['excluded_si_files'], rules_sha256=file_hash(rules_path),
        provenance='Local user-supplied dialogue. Includes AI-authored/synthetic material; '
                   'not evidence of actual chat or human review. Per-file authorship is not inferred.',
        license='Source-specific terms are not established by local ownership; no blanket redistribution license.',
        grouping='Blank-line-delimited conversations. Workbuddy files stay together; other conversations '
                 'share a split by normalized whole-conversation template with ASCII words/numbers masked. '
                 'Exact documents and long paragraphs are also checked. Semantic near-duplicates are not certified absent.')
    value['source_lock_id'] = fingerprint(value)
    write_json(output, value)
    progress('sources-frozen', files=len(entries), bytes=sum(e['bytes'] for e in entries), output=str(output))


def verify_sources(si_root, lock):
    if (lock.get('kind') != 'si-distillation-source-lock' or
            fingerprint({k: v for k, v in lock.items() if k != 'source_lock_id'}) != lock['source_lock_id']):
        raise ValueError('Invalid SI source lock')
    expected = {e['path']: e for e in lock['files']}
    actual = {p.relative_to(si_root).as_posix() for p in si_files(si_root, lock['exclusions'])}
    if actual != set(expected):
        raise ValueError('SI inventory changed; freeze a new source lock and use a fresh output')
    for name, entry in expected.items():
        if pin(secure_file(si_root, name)) != {k: entry[k] for k in ('bytes', 'sha256')}:
            raise ValueError('SI source changed: ' + name + '; freeze a new source lock and use a fresh output')


def choose(rng, weights):
    return rng.choices(list(weights), weights=list(weights.values()), k=1)[0]


def split_for(group, rules):
    value = int(fingerprint([rules['seed'], group])[:16], 16) / 2**64
    boundary = 0
    for split, weight in rules['si_split_shares'].items():
        boundary += weight
        if value < boundary:
            return split
    return 'test'


def template(text):
    return re.sub(r'[a-z0-9]+', '<slot>', normalized(text))


def source_bucket(source):
    if source in ('lccc', 'kdconv', 'crosswoz'):
        return 'public_dialogue'
    if source in ('mdn', 'kubernetes', 'tensorflow'):
        return 'technical'
    return source


def paragraphs(text):
    return {fingerprint(normalized(line)) for line in text.splitlines() if len(normalized(line)) >= 32}


def conversations(path):
    lines, start, number = [], 1, 0
    with path.open(encoding='utf-8') as stream:
        for line_number, line in enumerate(stream, 1):
            if line.strip():
                if not lines:
                    start = line_number
                lines.append(line.rstrip('\r\n'))
            elif lines:
                number += 1
                yield number, start, '\n'.join(lines)
                lines = []
        if lines:
            yield number + 1, start, '\n'.join(lines)


def index_documents(db, lm_data, manifest, si_root, lock, rules):
    db.executescript('''
        CREATE TABLE docs(id TEXT PRIMARY KEY, source TEXT, split TEXT, text TEXT,
                          origin TEXT, grp TEXT, file_key TEXT, priority TEXT, external INTEGER);
        CREATE TABLE paragraphs(id TEXT, split TEXT, PRIMARY KEY(id,split));
        CREATE TABLE readings(text TEXT PRIMARY KEY, spelling TEXT);
        CREATE TABLE pools(id TEXT PRIMARY KEY, query TEXT UNIQUE, split TEXT, source TEXT, file_key TEXT, row TEXT);
        CREATE TABLE done_docs(id TEXT PRIMARY KEY);
        CREATE TABLE stats(key TEXT PRIMARY KEY, count INTEGER);
    ''')
    for split in SPLITS:
        path = checked_file(lm_data, manifest, f'{split}.documents.jsonl')
        count = 0
        for row in read_jsonl(path):
            db.execute('INSERT INTO docs VALUES (?,?,?,?,?,?,?,?,?)',
                       (row['id'], source_bucket(row['source']), split, row['text'], row['origin'],
                        row['source'] + ':' + row['group'], row['source'],
                        fingerprint([rules['seed'], row['id']]), 0))
            db.executemany('INSERT OR IGNORE INTO paragraphs VALUES (?,?)', ((p, split) for p in paragraphs(row['text'])))
            count += 1
            if count % 10000 == 0:
                db.commit()
                if count % 100000 == 0:
                    progress('index-parent', split=split, documents=count)
        db.commit()
        progress('index-parent', split=split, documents=count)
    for entry in lock['files']:
        for number, first_line, text in conversations(secure_file(si_root, entry['path'])):
            identity = fingerprint(normalized(text))
            # All parent documents, including held-out documents, stay untouched.
            if db.execute('SELECT 1 FROM docs WHERE id=?', (identity,)).fetchone():
                bump(db, 'si_duplicate_document')
                continue
            group = ('file:' + entry['path'] if entry['source'] == 'si_workbuddy' and
                     not entry['path'].endswith('/chats.txt') else 'template:' + fingerprint(template(text)))
            split = split_for(group, rules)
            ps = paragraphs(text)
            if any(db.execute('SELECT 1 FROM paragraphs WHERE id=? AND split<>?', (p, split)).fetchone() for p in ps):
                bump(db, 'si_cross_split_paragraph')
                continue
            db.execute('INSERT INTO docs VALUES (?,?,?,?,?,?,?,?,?)',
                       (identity, entry['source'], split, text, f"{entry['path']}:conversation:{number}:line:{first_line}",
                        group, entry['path'], fingerprint([rules['seed'], identity]), 1))
            db.executemany('INSERT OR IGNORE INTO paragraphs VALUES (?,?)', ((p, split) for p in ps))
        db.commit()
    db.execute('CREATE INDEX source_docs ON docs(split,source,file_key,priority)')
    db.commit()


def bump(db, key, count=1):
    db.execute('INSERT INTO stats VALUES (?,?) ON CONFLICT(key) DO UPDATE SET count=count+excluded.count', (key, count))


def index_readings(db, binary, lexicon, directory):
    path = directory / 'readings.csv'
    subprocess.run([str(binary), 'lexicon', 'export', '--language', 'zh-Hans', str(lexicon), str(path)],
                   check=True, stdout=subprocess.DEVNULL)
    with path.open(encoding='utf-8-sig', newline='') as stream:
        for row in csv.DictReader(stream):
            text, reading = row['text'], row['reading']
            if row.get('kind', 'word') != 'word':
                continue
            if not 1 <= len(text) <= 16 or not all(HAN.fullmatch(c) for c in text) or not READING.fullmatch(reading):
                continue
            spelling = reading.replace("'", '').replace('ü', 'v')
            db.execute('INSERT INTO readings VALUES (?,?) ON CONFLICT(text) DO UPDATE SET spelling='
                       'CASE WHEN readings.spelling=excluded.spelling THEN readings.spelling ELSE NULL END',
                       (text, spelling))
    db.commit()
    path.unlink()


class DictionaryReadings:
    def __init__(self, db):
        self.db = db

    @lru_cache(maxsize=100000)
    def lookup(self, text):
        row = self.db.execute('SELECT spelling FROM readings WHERE text=?', (text,)).fetchone()
        return row is not None, row[0] if row else None

    def encode(self, text):
        result, offset = [], 0
        while offset < len(text):
            if text[offset].isascii() and text[offset].isalnum():
                end = offset + 1
                while end < len(text) and text[end].isascii() and text[end].isalnum():
                    end += 1
                result.append(text[offset:end])
                offset = end
                continue
            for end in range(min(len(text), offset + 16), offset, -1):
                found, spelling = self.lookup(text[offset:end])
                if found:
                    if spelling is None:
                        return None  # Do not resolve an ambiguous longest match with a shorter fallback.
                    result.append(spelling)
                    offset = end
                    break
            else:
                return None
        return ''.join(result)


def make_input(full, mode, rng):
    if mode == 'complete':
        return full
    if len(full) < 2:
        return None
    if mode == 'partial':
        return full[:rng.randint(max(1, len(full) - 3), len(full) - 1)]
    if mode == 'early':
        return full[:rng.randint(1, min(3, len(full) - 1))]
    positions = [i for i, c in enumerate(full) if c.isascii() and c.isalpha()]
    if not positions:
        return None
    index = rng.choice(positions)
    return full[:index] + rng.choice('abcdefghijklmnopqrstuvwxyz'.replace(full[index].lower(), '')) + full[index + 1:]


def proposals(doc, tokenizer, readings, rules):
    from llm.reranker_large.scoring import suffix

    rng = random.Random(fingerprint([rules['seed'], doc['id']]))
    chunks = list(CHUNKS.finditer(doc['text']))
    if not chunks:
        return
    seen = set()
    for _ in range(rules['proposals_per_document']):
        chunk = rng.choice(chunks)
        target_bucket = choose(rng, {k: v['share'] for k, v in rules['target_buckets'].items()})
        lo, hi = rules['target_buckets'][target_bucket]['characters']
        length = rng.randint(lo, hi)
        if length > chunk.end() - chunk.start():
            yield None, 'target_too_short'
            continue
        start = rng.randint(chunk.start(), chunk.end() - length)
        observed = doc['text'][start:start + length]
        if not HAN.search(observed):
            yield None, 'pure_english_target'
            continue
        full = readings.encode(observed)
        if not full:
            yield None, 'missing_or_ambiguous_reading'
            continue
        context_bucket = choose(rng, {k: v['share'] for k, v in rules['context_buckets'].items()})
        lo, hi = rules['context_buckets'][context_bucket]['tokens']
        # Never concatenate another speaker's message into host field context.
        before = doc['text'][:start].rsplit('\n', 1)[-1].rsplit('\t', 1)[-1]
        context = suffix(before, tokenizer, rng.randint(lo, hi))
        if len(tokenizer.encode(context)) - 2 < lo or not all(unicodedata.category(c) != 'Cc' for c in context):
            yield None, 'context_unavailable'
            continue
        mode = choose(rng, rules['input_shares'])
        spelling = make_input(full, mode, rng)
        if not spelling:
            yield None, 'input_unavailable'
            continue
        key = (start, length, context, spelling)
        if key in seen:
            continue
        seen.add(key)
        row = dict(id=fingerprint([doc['id'], key]), document_id=doc['id'], split=doc['split'],
                   input=spelling, context=context, observed_text=observed, full_input=full,
                   source=doc['source'], origin=doc['origin'], source_group=doc['grp'],
                   span_start=start, span_end=start + length, reading_reviewed=False,
                   case=dict(context=context_bucket, target=target_bucket, input=mode,
                             mixed_target=bool(re.search('[A-Za-z]', observed))))
        yield row, None


def unescape(text):
    def replace(match):
        token = match[0]
        if token.startswith('\\u{'):
            return chr(int(token[3:-1], 16))
        return {'\\\\': '\\', '\\n': '\n', '\\r': '\r', '\\t': '\t', '\\0': '\0'}[token]
    return re.sub(r'\\u\{[0-9a-fA-F]+\}|\\[\\nrt0]', replace, text)


class Engine:
    def __init__(self, binary, lexicon, grams, config, rules):
        command = [str(binary), '--config', str(config), 'candidates', str(lexicon), '--grams', str(grams),
                   '--languages', rules['languages'], '--pinyin-correction', rules['pinyin_correction'],
                   '--request-format', 'context-tsv', '--list', 'full', '--search', 'full']
        self.child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      text=True, encoding='utf-8', bufsize=1)

    def candidates(self, spelling, context, limit):
        self.child.stdin.write(spelling + '\t' + context + '\n')
        self.child.stdin.flush()
        rows = []
        identities = set()
        while True:
            line = self.child.stdout.readline()
            if not line:
                raise RuntimeError('Candidate CLI exited; rebuild Release si-cli with context-tsv support')
            if line == '\n':
                return rows
            language, consumed, kind, score, text = line.rstrip('\n').split('\t', 4)
            if (language not in ('zh-Hans', 'en', 'mixed') or int(consumed) != len(spelling.encode('utf-8'))
                    or kind not in ('exact', 'completion', 'correction')):
                continue
            candidate = dict(text=unescape(text), language=language)
            identity = (candidate['text'], language)
            if identity not in identities and len(rows) < limit:
                identities.add(identity)
                rows.append(candidate)

    def close(self):
        self.child.stdin.close()
        self.child.stdout.close()
        try:
            result = self.child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.child.terminate()
            self.child.wait(timeout=10)
            raise RuntimeError('Candidate CLI did not exit')
        if result:
            raise RuntimeError('Candidate CLI failed')


def quotas(total, weights):
    values = {k: int(total * v) for k, v in weights.items()}
    order = sorted(weights, key=lambda k: (-(total * weights[k] - values[k]), k))
    for key in order[:total - sum(values.values())]:
        values[key] += 1
    return values


def generate(db, tokenizer, engine, rules, config):
    from llm.reranker_large.scoring import validate_pool

    db.row_factory = sqlite3.Row
    readings = DictionaryReadings(db)
    last_report = time.monotonic()
    # Protect held-out repeated short queries before selecting training pools.
    for split in ('test', 'validation', 'train'):
        for source, target in quotas(rules['pools'][split], rules['source_shares']).items():
            count = db.execute('SELECT COUNT(*) FROM pools WHERE split=? AND source=?', (split, source)).fetchone()[0]
            file_counts = Counter({r[0]: r[1] for r in db.execute(
                'SELECT file_key,COUNT(*) FROM pools WHERE split=? AND source=? GROUP BY file_key', (split, source))})
            # Interleave source files before exhausting a large generated file.
            docs = db.execute('SELECT d.* FROM docs d WHERE split=? AND source=? '
                              'AND NOT EXISTS(SELECT 1 FROM done_docs x WHERE x.id=d.id) '
                              'ORDER BY row_number() OVER (PARTITION BY file_key ORDER BY priority),priority',
                              (split, source))
            for raw in docs:
                if count >= target:
                    break
                doc = dict(raw)
                with db:
                    for row, reason in proposals(doc, tokenizer, readings, rules):
                        if count >= target:
                            break
                        if source.startswith('si_') and file_counts[doc['file_key']] >= max(1, math.ceil(target * rules['max_si_file_share'])):
                            bump(db, 'si_file_cap')
                            break
                        if reason:
                            bump(db, reason)
                            continue
                        bump(db, 'proposals')
                        if len(tokenizer.encode(row['observed_text'])) - 2 > config['scoring']['candidate_tokens']:
                            bump(db, 'observed_token_limit')
                            continue
                        row['candidates'] = engine.candidates(row['input'], row['context'], config['scoring']['max_candidates'])
                        if len(row['candidates']) < 2:
                            bump(db, 'fewer_than_two_candidates')
                            continue
                        if not validate_pool(row, tokenizer, config):
                            bump(db, 'candidate_token_limit')
                            continue
                        if row['context'] + row['observed_text'] not in doc['text']:
                            raise AssertionError('Noncontiguous source span')
                        key = fingerprint([normalized(row['context']), normalized(row['input']),
                                           sorted((normalized(c['text']), c['language']) for c in row['candidates'])])
                        previous = db.execute('SELECT split FROM pools WHERE query=?', (key,)).fetchone()
                        if previous:
                            bump(db, 'duplicate_query' if previous[0] == split else 'cross_split_query')
                            continue
                        row['observed_in_pool'] = any(c['text'] == row['observed_text'] for c in row['candidates'])
                        db.execute('INSERT INTO pools VALUES (?,?,?,?,?,?)',
                                   (row['id'], key, split, source, doc['file_key'], json.dumps(row, ensure_ascii=False)))
                        count += 1
                        file_counts[doc['file_key']] += 1
                    db.execute('INSERT INTO done_docs VALUES (?)', (doc['id'],))
                if time.monotonic() - last_report >= 10:
                    progress('generate', split=split, source=source, pools=count, target=target)
                    last_report = time.monotonic()
            progress('source-finished', split=split, source=source, pools=count, target=target)


def publish(db, output, lm_data, manifest, tokenizer, config, rules, lock, identity, allow_shortfall):
    from llm.reranker_large.scoring import validate_pool

    counts = {s: dict(db.execute('SELECT source,COUNT(*) FROM pools WHERE split=? GROUP BY source', (s,))) for s in SPLITS}
    missing = {s: {k: n - counts[s].get(k, 0) for k, n in quotas(rules['pools'][s], rules['source_shares']).items()
                   if counts[s].get(k, 0) < n} for s in SPLITS}
    if any(missing.values()) and not allow_shortfall:
        raise ValueError('Insufficient eligible pools; work is retained. Inspect source-finished counts, '
                         'then use --resume --allow-shortfall to explicitly publish the actual counts: ' + json.dumps(missing))
    if any(not sum(v.values()) for v in counts.values()):
        raise ValueError('Every split needs at least one pool')
    with new_directory(output) as staged:
        metadata = staged / 'metadata/generation'
        metadata.mkdir(parents=True)
        write_json(metadata / 'sources.json', lock)
        write_json(metadata / 'sampling.json', rules)
        write_json(metadata / 'identity.json', identity)
        shutil.copyfile(__file__, metadata / 'producer.py')
        parent = staged / 'metadata/pretraining'
        parent.mkdir()
        shutil.copyfile(Path(lm_data) / 'manifest.json', parent / 'manifest.json')
        for name in manifest['files']:
            if name in ('NOTICE.md', 'source-lock.json') or name.startswith('metadata/'):
                path = checked_file(lm_data, manifest, name)
                target = parent / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
        # Retain each selected natural-text document, including external SI documents.
        with (metadata / 'documents.jsonl').open('w', encoding='utf-8') as stream:
            for row in db.execute('SELECT * FROM docs WHERE id IN (SELECT json_extract(row,\'$.document_id\') FROM pools) ORDER BY id'):
                stream.write(json.dumps(dict(row), ensure_ascii=False) + '\n')
        sources = [*manifest['sources'], dict(id='si-distillation', origin=lock['provenance'],
                    revision=lock['source_lock_id'], license=lock['license'])]
        write_json(staged / 'source-lock.json', dict(schema_version=1, sources=sources,
            parent_lm_dataset_id=manifest['dataset_id'], generation=identity,
            document_registry='metadata/generation/documents.jsonl'))
        (staged / 'NOTICE.md').write_text('# Distillation source provenance\n\n'
            'Selected natural-text source documents, local SI inventory, production resources and sampling rules '
            'are retained under metadata/. SI readings are automatically dictionary-derived and unreviewed. '
            'No target injection or reviewed ranking labels. No blanket redistribution license is assigned.\n', encoding='utf-8')
        distributions, recalled = {}, {}
        for split in SPLITS:
            writer = PoolWriter(staged, split)
            stats = Counter()
            hits = 0
            try:
                for result in db.execute('SELECT row FROM pools WHERE split=? ORDER BY id', (split,)):
                    row = json.loads(result[0])
                    validate_pool(row, tokenizer, config)
                    writer.append(row)
                    for key in ('context', 'target', 'input', 'mixed_target'):
                        stats[f'{key}:{row["case"][key]}'] += 1
                    stats[f'context_tokens:{len(tokenizer.encode(row["context"])) - 2}'] += 1
                    stats[f'target_tokens:{len(tokenizer.encode(row["observed_text"])) - 2}'] += 1
                    stats[f'candidates:{len(row["candidates"])}'] += 1
                    hits += row['observed_in_pool']
            finally:
                writer.close()
            distributions[split] = dict(stats)
            recalled[split] = dict(pools=writer.count, observed_in_pool=hits,
                                   note='Natural-text target coverage, not reviewed ranking accuracy.')
        report = dict(requested=rules['pools'], source_counts=counts, shortfalls=missing,
                      distributions=distributions, observed_coverage=recalled,
                      exclusions=dict(db.execute('SELECT key,count FROM stats')),
                      limitations=['Readings and ranking references are not human-reviewed.',
                                   'Template masking/exact-paragraph checks do not prove semantic independence.',
                                   'Proposal bucket shares can differ from accepted pool shares.'])
        write_json(metadata / 'report.json', report)
        return finish_manifest(staged, dict(schema_version=1, kind='si-student-pools',
            lm_dataset_id=manifest['dataset_id'], tokenizer_digest=tokenizer.digest,
            limits={k: config['scoring'][k] for k in ('max_candidates', 'context_tokens', 'candidate_tokens')},
            splits={s: {'pools': sum(counts[s].values())} for s in SPLITS}, teacher=None,
            document_registry='metadata/generation/documents.jsonl', generation=identity,
            preparation_code=file_hash(Path(__file__))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--freeze-sources', action='store_true', help='Only pin the local TXT inventory; no extraction or candidate generation')
    parser.add_argument('--sources', type=Path, default=ROOT / 'configs/distillation-sources.json')
    parser.add_argument('--sampling', type=Path, default=ROOT / 'configs/distillation-data.json')
    parser.add_argument('--si-root', type=Path, default=REPO / 'corpus/chinese/raw/si')
    parser.add_argument('--data', type=Path, default=ROOT / 'data/prepared/student-15m-v1/lm')
    parser.add_argument('--config', type=Path, default=ROOT / 'configs/distill.json')
    parser.add_argument('--binary', type=Path, default=REPO / 'target/release/si-cli')
    parser.add_argument('--lexicon', type=Path, default=REPO / 'Data/Engine/main.silex')
    parser.add_argument('--grams', type=Path, default=REPO / 'Data/Engine/words.sigram')
    parser.add_argument('--engine-config', type=Path, default=REPO / 'config/si.conf')
    parser.add_argument('--output', type=Path, default=ROOT / 'data/prepared/student-15m-v1/pools')
    for split in SPLITS:
        parser.add_argument('--' + split + '-pools', type=int)
    parser.add_argument('--resume', action='store_true', help='Resume retained document index and completed document transactions')
    parser.add_argument('--allow-shortfall', action='store_true', help='Explicitly publish smaller source/split counts without quota redistribution')
    args = parser.parse_args()
    args.si_root = args.si_root.resolve()
    if args.freeze_sources:
        freeze_sources(args.si_root, args.sampling, args.sources)
        return
    config, rules, lock = load_config(args.config), rules_at(args.sampling), read_json(args.sources)
    if lock['rules_sha256'] != file_hash(args.sampling):
        raise ValueError('Sampling rules changed; freeze a fresh source lock')
    for split in SPLITS:
        override = getattr(args, split + '_pools')
        if override is not None:
            if override <= 0:
                raise ValueError('Pool budgets must be positive')
            rules['pools'][split] = override
    if config['scoring']['context_tokens'] != 16 or config['scoring']['candidate_tokens'] != 16:
        raise ValueError('Sampling buckets require the student distillation 16/16 token limits')
    if args.output.exists():
        raise FileExistsError('Choose a fresh immutable output directory')
    verify_sources(args.si_root, lock)
    manifest = manifest_at(args.data, 'si-character-lm')
    tokenizer = Tokenizer.load(checked_file(args.data, manifest, 'tokenizer.json'))
    if (tokenizer.digest != manifest['tokenizer_digest'] or manifest['model_limits'] !=
            {k: config['model'][k] for k in ('vocab_size', 'context')}):
        raise ValueError('Parent tokenizer/model limits mismatch')
    resources = {k: pin(getattr(args, k).resolve()) for k in ('binary', 'lexicon', 'grams', 'engine_config')}
    help_result = subprocess.run([str(args.binary.resolve()), '--help'], text=True, capture_output=True, check=True)
    if 'context-tsv' not in help_result.stdout:
        raise ValueError('Rebuild the offline CLI first: cargo build --release --locked -p si-cli')
    identity = dict(parent_lm_dataset_id=manifest['dataset_id'], source_lock_id=lock['source_lock_id'],
                    rules=rules, model_limits=config['scoring'], resources=resources,
                    producer_sha256=file_hash(Path(__file__)), consumer_code_identity=code_identity())
    work = args.output.resolve().with_name('.' + args.output.name + '.work')
    if work.is_symlink():
        raise ValueError('Work directory must not be a symlink')
    if work.exists():
        if not args.resume or read_json(work / 'identity.json') != identity:
            raise ValueError('Work directory exists; use --resume with identical inputs or choose a new --output')
    else:
        if args.resume:
            raise ValueError('No work directory to resume')
        work.mkdir(parents=True)
        write_json(work / 'identity.json', identity)
    lock_stream = (work / 'writer.lock').open('a')
    try:
        fcntl.flock(lock_stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_stream.close()
        raise ValueError('Another generator is using this work directory') from None
    database = work / 'work.sqlite3'
    ready = (work / 'indexed.json').exists()
    if not ready:
        # Only this owned scratch database is rebuilt after interrupted indexing.
        for name in ('work.sqlite3', 'work.sqlite3-wal', 'work.sqlite3-shm', 'work.sqlite3-journal', 'readings.csv'):
            (work / name).unlink(missing_ok=True)
    db = sqlite3.connect(database)
    try:
        if not ready:
            index_documents(db, args.data, manifest, args.si_root, lock, rules)
            index_readings(db, args.binary.resolve(), args.lexicon.resolve(), work)
            write_json(work / 'indexed.json', dict(ready=True))
        engine = Engine(args.binary.resolve(), args.lexicon.resolve(), args.grams.resolve(), args.engine_config.resolve(), rules)
        try:
            generate(db, tokenizer, engine, rules, config)
        finally:
            engine.close()
        # Verify all frozen inputs again before publication, including resumed input bytes.
        verify_sources(args.si_root, lock)
        for key, expected in resources.items():
            if pin(getattr(args, key).resolve()) != expected:
                raise ValueError('Engine resource changed: ' + key)
        if manifest_at(args.data, 'si-character-lm')['dataset_id'] != manifest['dataset_id']:
            raise ValueError('Parent LM manifest changed')
        result = publish(db, args.output, args.data, manifest, tokenizer, config, rules, lock, identity, args.allow_shortfall)
        progress('complete', output=str(args.output), dataset_id=result['dataset_id'], splits=result['splits'])
    finally:
        db.close()
        lock_stream.close()


if __name__ == '__main__':
    main()
