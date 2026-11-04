"""Load frozen public suites without importing any model or training code."""

from collections import Counter
import hashlib
import json
from pathlib import Path
import unicodedata

ROOT = Path(__file__).resolve().parent
TASKS = ('ranking', 'correction', 'pinyin_to_hanzi')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_new(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8') as handle:
        handle.write(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def normalized(text):
    # Only for leakage checks; scoring and committed output remain byte-exact.
    return unicodedata.normalize('NFKC', text).casefold()


def validate_rows(rows, task):
    identities, families, inputs, targets = set(), {}, {}, {}
    for row in rows:
        for field in ('id', 'family_id', 'category', 'track'):
            if not isinstance(row.get(field), str) or not row[field]:
                raise ValueError('Missing case field: ' + field)
        if row['id'] in identities or row.get('split') not in ('dev', 'test'):
            raise ValueError('Repeated ID or invalid split: ' + row['id'])
        identities.add(row['id'])
        split, family = row['split'], row['family_id']
        if families.setdefault(family, split) != split:
            raise ValueError('Family crosses dev/test: ' + family)
        if not isinstance(row.get('context'), str) or type(row.get('diagnostic')) is not bool:
            raise ValueError('Invalid context/diagnostic: ' + row['id'])
        references = row.get('references')
        if not isinstance(references, list) or not references:
            raise ValueError('Missing references: ' + row['id'])
        if not all(isinstance(text, str) and text for text in references):
            raise ValueError('Invalid reference text: ' + row['id'])
        if task == 'ranking':
            pool = row.get('candidates')
            if not isinstance(pool, list) or len(pool) > 32 or not all(isinstance(t, str) and t for t in pool):
                raise ValueError('Invalid candidate pool: ' + row['id'])
            details = row.get('candidate_details')
            if details is not None and ([v['text'] for v in details] != pool
                    or len({v['identity'] for v in details}) != len(details)):
                raise ValueError('Candidate identity/text mismatch: ' + row['id'])
        else:
            if not isinstance(row.get('input'), str) or not row['input']:
                raise ValueError('Invalid input: ' + row['id'])
            for value, assignments in ((row['input'], inputs), *((r, targets) for r in references)):
                key = normalized(value)
                if assignments.setdefault(key, split) != split:
                    raise ValueError('Normalized input/reference crosses dev/test: ' + row['id'])
    if not rows:
        raise ValueError('Empty suite')


def load(task, split='test', suite=None, root=ROOT):
    if task not in TASKS or split not in ('dev', 'test'):
        raise ValueError('Unknown task or split')
    root = Path(root)
    catalog = read_json(root / 'catalog.json')
    if catalog.get('schema_version') != 1:
        raise ValueError('Unsupported catalog schema')
    suite = suite or catalog['defaults'][task]
    entry = next((v for v in catalog['suites'] if v['task'] == task and v['suite'] == suite), None)
    if entry is None:
        raise ValueError('Unknown suite for task: ' + suite)
    directory = root / task / suite
    manifest_path = directory / 'manifest.json'
    if digest(manifest_path) != entry['manifest_sha256']:
        raise ValueError('Suite manifest modified: ' + str(manifest_path))
    manifest = read_json(manifest_path)
    if manifest.get('schema_version') != 1 or manifest.get('revision') != suite:
        raise ValueError('Unsupported suite manifest')
    if not {'dev.jsonl', 'test.jsonl', 'provenance.json'} <= manifest['files'].keys():
        raise ValueError('Incomplete manifest')
    for name, expected in manifest['files'].items():
        path = directory / name
        if not path.resolve().is_relative_to(directory.resolve()) or digest(path) != expected:
            raise ValueError('Suite file modified: ' + name)
    rows = []
    for part in ('dev', 'test'):
        values = [json.loads(line) for line in (directory / (part + '.jsonl')).read_text(encoding='utf-8').splitlines()]
        if not values or any(row.get('split') != part for row in values):
            raise ValueError('Incorrect split file: ' + part)
        rows.extend(values)
    validate_rows(rows, task)
    counts = dict(Counter(row['split'] for row in rows))
    expected_counts = manifest.get('coverage', {}).get('splits', manifest.get('splits'))
    if counts != expected_counts:
        raise ValueError('Manifest split counts differ from rows')
    provenance = read_json(directory / 'provenance.json')
    if task == 'ranking':
        for name in ('lexical.tsv', 'additional.jsonl'):
            if digest(root / task / name) != provenance['builder_sources'][name]:
                raise ValueError('Authored ranking source modified: ' + name)
    selected = [row for row in rows if row['split'] == split]
    return {
        'schema_version': 1, 'task': task, 'suite': suite, 'split': split,
        'dataset_sha256': entry['manifest_sha256'],
    }, selected, provenance


def requests(identity, rows):
    # No references, family/category labels, diagnostics, overlap or expected policies.
    keys = ('id', 'input', 'context', 'candidates', 'candidate_details')
    return {**identity, 'cases': [{k: row[k] for k in keys if k in row} for row in rows]}
