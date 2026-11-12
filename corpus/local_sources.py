"""Snapshot and read explicit local SI text and the pinned Chinese dialogue download."""

import json
from pathlib import Path
import shutil
import zipfile

if __package__:
    from .common import digest
else:
    from common import digest

DATASETS = {'lccc-base', 'kdconv', 'crosswoz', 'oasst1'}
CHINESE_LANGUAGES = {'zh', 'zh-cn', 'zh-tw', 'zh-hans', 'zh-hant'}


def local_path(root, name):
    relative = Path(name)
    path = root / relative
    if relative.is_absolute() or '..' in relative.parts or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Unsafe local source path')
    if not path.is_file():
        raise ValueError('Missing local source file: ' + str(relative))
    return path


def fingerprint(root, name, expected=None):
    path = local_path(root, name)
    result = {'path': name, 'size': path.stat().st_size, 'sha256': digest(path)}
    if expected and any(result[key] != expected[key] for key in ('size', 'sha256')):
        raise ValueError('Local source checksum mismatch: ' + name)
    return result


def snapshot(kind, root):
    root = Path(root)
    if kind == 'si':
        names = sorted(path.relative_to(root).as_posix() for path in root.rglob('*.txt'))
        if not names:
            raise ValueError('SI source contains no TXT files: ' + str(root))
        return {'id': 'si', 'kind': 'si', 'files': [fingerprint(root, name) for name in names],
                'provenance': 'Local user-supplied TXT; synthetic-dialogues-v1 is AI-authored synthetic dialogue, not real chat transcripts.'}
    if kind != 'dialogue':
        raise ValueError('Unknown local source kind')
    manifest = local_path(root, 'download-manifest.json')
    value = json.loads(manifest.read_text(encoding='utf-8'))
    if value.get('schema_version') != 1 or value.get('kind') != 'raw-conversation-downloads':
        raise ValueError('Unsupported local dialogue download manifest')
    declared = value['sources']
    if not declared or len({row['id'] for row in declared}) != len(declared):
        raise ValueError('Empty or duplicate dialogue dataset IDs')
    if any(row['id'] not in DATASETS or not row.get('files') for row in declared):
        raise ValueError('Unsupported or empty dialogue dataset')
    # LCCC-base is already extracted by the standalone pinned lccc source.
    datasets = [row for row in declared if row['id'] != 'lccc-base']
    if not datasets:
        raise ValueError('No dialogue datasets remain after excluding LCCC-base')
    files = {'download-manifest.json': fingerprint(root, 'download-manifest.json')}
    for dataset in datasets:
        for entry in dataset['files']:
            if Path(entry['path']).is_absolute() or '..' in Path(entry['path']).parts:
                raise ValueError('Unsafe local source path')
            name = dataset['id'] + '/' + entry['path']
            if name in files:
                raise ValueError('Duplicate dialogue file')
            files[name] = fingerprint(root, name, entry)
        for entry in dataset.get('documents', []):
            files[entry['path']] = fingerprint(root, entry['path'], entry)
    for folder in ('licenses', 'metadata'):
        for path in sorted((root / folder).rglob('*')):
            if path.is_file():
                name = path.relative_to(root).as_posix()
                files.setdefault(name, fingerprint(root, name))
    if (root / 'acquisition.json').exists():
        files['acquisition.json'] = fingerprint(root, 'acquisition.json')
    return {'id': 'dialogue', 'kind': 'dialogue', 'datasets': datasets,
            'files': [files[name] for name in sorted(files)],
            'selection': 'KdConv/CrossWOZ utterances and OASST1 Chinese-language messages, with original parent IDs. '
                         'LCCC-base is extracted separately as lccc. No quality filtering or line deduplication.'}


def si_documents(source, root, counts):
    for entry in source['files']:
        name = entry['path']
        conversation, first, lines = 0, 1, []
        with local_path(root, name).open(encoding='utf-8') as handle:
            for number, line in enumerate(handle, 1):
                counts['records_read'] += 1
                if line.strip():
                    if not lines:
                        first = number
                    lines.append(line.rstrip('\n'))
                elif lines:
                    conversation += 1
                    yield f'{name}/conversation:{conversation}', '\n'.join(lines) + '\n\n', {
                        'path': name, 'source_first_line': first, 'conversation': conversation}
                    lines = []
            if lines:
                conversation += 1
                yield f'{name}/conversation:{conversation}', '\n'.join(lines) + '\n\n', {
                    'path': name, 'source_first_line': first, 'conversation': conversation}


def require_text(value, location):
    if not isinstance(value, str):
        raise ValueError('Invalid dialogue text at ' + location)
    return value


def dialogue_documents(source, root, counts):
    for dataset in source['datasets']:
        identity = dataset['id']
        for entry in dataset['files']:
            name = identity + '/' + entry['path']
            path = local_path(root, name)
            split = path.name.split('.')[0].split('-')[0]
            common = {'dataset': identity, 'path': name, 'split': split}
            if identity == 'oasst1':
                try:
                    import pyarrow.parquet as parquet
                except ImportError as error:
                    raise RuntimeError('OASST1 requires corpus/english/requirements.txt (pyarrow).') from error
                for batch in parquet.ParquetFile(path).iter_batches(batch_size=1024, columns=[
                        'message_id', 'parent_id', 'message_tree_id', 'lang', 'role', 'text']):
                    for row in batch.to_pylist():
                        counts['records_read'] += 1
                        if row['lang'] not in CHINESE_LANGUAGES:
                            counts['non_chinese_messages'] += 1
                            continue
                        origin = name + '/message:' + require_text(row['message_id'], name)
                        text = require_text(row['text'], origin)
                        yield origin, text, {**common, 'message_id': row['message_id'],
                                             'parent_id': row['parent_id'], 'conversation': row['message_tree_id'],
                                             'role': row['role'], 'language': row['lang']}
                continue
            if identity == 'kdconv':
                conversations = json.loads(path.read_text(encoding='utf-8'))
                if not isinstance(conversations, list):
                    raise ValueError('Invalid KdConv dialogue collection')
                pairs = enumerate(conversations)
                field = 'message'
            else:
                with zipfile.ZipFile(path) as archive:
                    member = path.name.removesuffix('.zip')
                    if archive.namelist() != [member]:
                        raise ValueError('Unexpected CrossWOZ archive members')
                    with archive.open(member) as handle:
                        conversations = json.load(handle)
                if not isinstance(conversations, dict):
                    raise ValueError('Invalid CrossWOZ dialogue collection')
                pairs = conversations.items()
                field = 'content'
            for conversation, row in pairs:
                counts['records_read'] += 1
                messages = row['messages']
                if not isinstance(messages, list):
                    raise ValueError('Invalid dialogue messages')
                for turn, message in enumerate(messages):
                    origin = f'{name}/conversation:{conversation}/turn:{turn}'
                    yield origin, require_text(message[field], origin), {
                        **common, 'conversation': conversation, 'turn': turn,
                        **({'role': message['role']} if 'role' in message else {})}


def copy_attribution(source, root, stage):
    if source['kind'] != 'dialogue':
        return
    data_files = {dataset['id'] + '/' + entry['path']
                  for dataset in source['datasets'] for entry in dataset['files']}
    for entry in source['files']:
        if entry['path'] not in data_files:
            target = stage / 'attribution' / entry['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(local_path(root, entry['path']), target)
