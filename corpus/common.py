"""Paths, checksums and immutable output directories for offline corpus tools."""

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
CHINESE = ROOT / 'chinese'
LOCK = CHINESE / 'sources.lock.json'


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        while chunk := handle.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def load_sources(lock_path=LOCK, data_root=CHINESE):
    lock = json.loads(lock_path.read_text(encoding='utf-8'))
    if lock['schema_version'] != 1 or lock['language'] != 'zh-Hans':
        raise ValueError('Unsupported corpus source lock')
    seen = set()
    for source in lock['sources']:
        if (not re.fullmatch('[a-z][a-z0-9-]*', source['id'])
                or source['id'] in seen
                or not re.fullmatch(r'\d{8}' if source['kind'] == 'wikipedia' else '[0-9a-f]{40}', source['revision'])
                or source['kind'] not in ('lccc', 'mc4', 'markdown', 'wikipedia')
                or not re.fullmatch('[0-9a-f]{64}', source['sha256'])
                or type(source['size']) is not int or source['size'] <= 0):
            raise ValueError('Invalid corpus source record')
        path = Path(source['path'])
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Invalid corpus archive path')
        if source['kind'] == 'wikipedia' and not re.fullmatch('[0-9a-f]{40}', source.get('sha1', '')):
            raise ValueError('Wikipedia requires its official SHA-1')
        documents = [source[key] for key in ('license_document', 'dataset_card') if key in source]
        documents += source.get('additional_documents', [])
        for document in documents:
            path = (data_root / document['path']).resolve()
            if (not any(path.is_relative_to((data_root / folder).resolve()) for folder in ('licenses', 'metadata'))
                    or digest(path) != document['sha256']):
                raise ValueError('Corpus attribution checksum mismatch: ' + source['id'])
        seen.add(source['id'])
    return lock['sources']


def verified_archive(source, raw_root):
    path = Path(raw_root) / source['id'] / source['path']
    if source.get('kind') == 'wikipedia':
        if __package__:
            from .wikipedia import verify
        else:
            from wikipedia import verify
        verify(path, source)
        return path
    if path.stat().st_size != source['size'] or digest(path) != source['sha256']:
        raise ValueError('Corpus archive checksum mismatch: ' + source['id'])
    return path


@contextmanager
def new_directory(destination):
    """Stage a whole bundle; leave existing bundles and failed preparation untouched."""
    destination = Path(destination).resolve()
    if destination.exists():
        raise FileExistsError('Choose a new output directory: ' + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = Path(tempfile.mkdtemp(prefix='.' + destination.name + '-', dir=destination.parent))
    try:
        yield staged
        if destination.exists():
            raise FileExistsError('Output appeared during preparation: ' + str(destination))
        staged.rename(destination)
    finally:
        if staged.exists():
            shutil.rmtree(staged)
