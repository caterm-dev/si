"""Read verified local conversation extracts with their original split and group identities."""

from itertools import islice
import json
from pathlib import Path
import shutil

from .settings import file_hash, read_json

COLLECTIONS = {'dialogue': 'dialogue', 'chinese-chatbot-corpus': 'chinese-corpus', 'si': 'si'}
UPSTREAM_SPLITS = {'train': 'train', 'dev': 'validation', 'val': 'validation',
                   'validation': 'validation', 'test': 'test', None: None}


def prepared_source(root, name):
    path = Path(root) / COLLECTIONS[name]
    manifest_path = path / 'manifest.json'
    revision = file_hash(manifest_path)
    manifest = read_json(manifest_path)
    if (manifest.get('schema_version') != 2 or manifest.get('source', {}).get('id') != name
            or manifest.get('extraction_contract') != 'complete-simplified-text-lines-v2'):
        raise ValueError('Invalid prepared dialogue manifest: ' + name)
    files = manifest['files']
    if not {'text.txt', 'documents.jsonl'} <= files.keys():
        raise ValueError('Prepared dialogue source is missing text or document metadata: ' + name)
    for filename, pin in files.items():
        relative = Path(filename)
        candidate = (path / relative).resolve()
        if (relative.is_absolute() or '..' in relative.parts or not candidate.is_relative_to(path.resolve())
                or (filename not in ('text.txt', 'documents.jsonl') and not filename.startswith('attribution/'))
                or candidate.stat().st_size != pin['bytes'] or file_hash(candidate) != pin['sha256']):
            raise ValueError('Prepared dialogue checksum or path mismatch: ' + filename)
    return {'id': name, 'kind': 'prepared-dialogue', 'revision': revision, 'files': files,
            'license': 'see per-dataset attribution'}, path


def prepared_documents(path, counts):
    local_si = read_json(path / 'manifest.json')['source']['id'] == 'si'
    with (path / 'text.txt').open(encoding='utf-8') as text, \
            (path / 'documents.jsonl').open(encoding='utf-8') as metadata:
        next_line = 1
        for line in metadata:
            row = json.loads(line)
            counts['records_read'] += 1
            length = row['lines']
            if row['first_line'] != next_line or type(length) is not int or length < 0:
                raise ValueError('Invalid prepared dialogue text range')
            lines = list(islice(text, length))
            if len(lines) != length:
                raise ValueError('Truncated prepared dialogue text range')
            next_line += length
            if local_si:
                yield row['origin'], ''.join(lines), ('si', row['origin'], None)
                continue
            dataset = row['dataset']
            if dataset == 'lccc-base':
                counts['excluded_separate_lccc'] += 1
                continue
            if row['split'] not in UPSTREAM_SPLITS or row['conversation'] is None:
                raise ValueError('Invalid prepared dialogue split or conversation')
            # Weibo post/reply files and OASST1 message trees share IDs across paths.
            namespace = dataset if dataset in ('oasst1', 'weibo') else row['path']
            group = f'{dataset}:{namespace}:{row["conversation"]}'
            yield row['origin'], ''.join(lines), (dataset, group, UPSTREAM_SPLITS[row['split']])
        if next(text, None) is not None:
            raise ValueError('Unreferenced text in prepared dialogue source')


def copy_prepared_attribution(source, path, staged):
    pins = {'manifest.json': source['revision']}
    pins.update({name: pin['sha256'] for name, pin in source['files'].items() if name.startswith('attribution/')})
    for name, expected in pins.items():
        target = staged / 'metadata' / source['id'] / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path / name, target)
        if file_hash(target) != expected:
            raise ValueError('Prepared dialogue attribution changed: ' + name)
