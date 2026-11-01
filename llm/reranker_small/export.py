"""Export inference-only weights with the actual selected data notices/provenance."""

import argparse
import json
from pathlib import Path
import shutil

import torch

from corpus.common import new_directory
from .runtime import atomic_checkpoint, load_checkpoint
from .settings import file_hash, fingerprint, read_json, write_json


def export(checkpoint_path, data_path, output):
    checkpoint, _, _ = load_checkpoint(checkpoint_path, torch.device('cpu'))
    data_path = Path(data_path)
    manifest = read_json(data_path / 'manifest.json')
    if (fingerprint({key: value for key, value in manifest.items() if key != 'dataset_id'}) != manifest['dataset_id']
            or manifest['dataset_id'] != checkpoint['dataset_id']):
        raise ValueError('Export data provenance differs from the trained checkpoint')
    with new_directory(output) as staged:
        payload = {key: checkpoint[key] for key in ('schema_version', 'kind', 'config', 'model', 'tokenizer',
                   'tokenizer_digest', 'dataset_id', 'step', 'code_identity')}
        payload['inference_only'] = True
        atomic_checkpoint(staged / 'model.pt', payload)
        for name, expected in manifest['files'].items():
            if name not in ('NOTICE.md', 'source-lock.json', 'tokenizer.json') and not name.startswith(('licenses/', 'metadata/')):
                continue
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts or file_hash(data_path / name) != expected:
                raise ValueError('Export attribution checksum/path mismatch')
            target = staged / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(data_path / name, target)
        write_json(staged / 'manifest.json', {
            'schema_version': 1, 'kind': 'si-character-lm-inference',
            'dataset_id': manifest['dataset_id'], 'checkpoint_sha256': file_hash(checkpoint_path),
            'step': checkpoint['step'], 'sources': manifest['sources'],
            'files': {str(path.relative_to(staged)): file_hash(path) for path in sorted(staged.rglob('*')) if path.is_file()},
            'note': 'FP32 baseline weights. Data terms retained separately; no blanket model-weight license is assigned. '
                    'No native inference integration or quantization is implemented.',
        })
    return {'output': str(output), 'step': checkpoint['step'], 'dataset_id': manifest['dataset_id']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--data', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(export(args.checkpoint, args.data, args.output), indent=2))
