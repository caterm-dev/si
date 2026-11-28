"""Export trusted SI checkpoints for the local si-neural inference runtime."""

import argparse
import hashlib
import json
from pathlib import Path
import tempfile

import torch

from .pinyin_to_text import runtime as pinyin
from .reranker_small import runtime as reranker


def export(kind, checkpoint, output):
    if output.exists():
        raise ValueError('Choose a new output directory')
    output.parent.mkdir(parents=True, exist_ok=True)
    with checkpoint.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    backend = pinyin if kind == 'pinyin' else reranker
    payload, model, tokenizer = backend.load_checkpoint(checkpoint, torch.device('cpu'))
    tensors = dict(model.state_dict())
    # The output projection shares the embedding in both architectures.
    if tensors.pop('output.weight').data_ptr() != tensors['embedding.weight'].data_ptr():
        raise ValueError('Expected a tied output projection')
    if kind == 'pinyin':
        tensors['positions'] = model.positions
    if sum(tensor.numel() * 4 for tensor in tensors.values()) > 512 * 1024 * 1024:
        raise ValueError('Checkpoint exceeds the Rust prototype weight limit')
    config = payload['config']
    manifest = {'schema': 1, 'kind': kind, 'model': model.config, 'characters': tokenizer.characters,
                'length_penalty': config['decoding' if kind == 'pinyin' else 'scoring']['length_penalty'],
                'checkpoint_sha256': checksum, 'dataset_id': payload['dataset_id'],
                'step': payload['step'], 'tensors': {}}
    if kind != 'pinyin':
        manifest['score_protocol'] = config['scoring'].get('protocol', 'mean-logp-v1')
        if config['scoring'].get('protocol', '').startswith('si-app-model-adjustment-'):
            manifest['app_score_mapping'] = config['scoring']
    with tempfile.TemporaryDirectory(dir=output.parent, prefix='.si-neural-') as temp:
        bundle = Path(temp) / 'bundle'
        bundle.mkdir(mode=0o700)
        with (bundle / 'weights.f32').open('wb') as stream:
            for name, tensor in sorted(tensors.items()):
                values = tensor.detach().cpu().numpy().astype('<f4', copy=False)
                manifest['tensors'][name] = list(values.shape)
                stream.write(values.tobytes(order='C'))
        with checkpoint.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != checksum:
                raise ValueError('Checkpoint changed during export')
        (bundle / 'model.json').write_text(json.dumps(manifest, ensure_ascii=False, allow_nan=False) + '\n')
        bundle.rename(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=['pinyin', 'reranker'])
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    export(args.kind, args.checkpoint, args.output)


if __name__ == '__main__':
    main()
