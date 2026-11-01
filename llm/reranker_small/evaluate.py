"""Explicit held-out token-loss evaluation; this is not candidate ranking accuracy."""

import argparse
import json
import math
from pathlib import Path

import torch

from .data import load_bundle
from .runtime import load_checkpoint, select_device, validation_loss
from .settings import file_hash, write_json


def evaluate(checkpoint_path, data_path, output, split='validation', device_name='mps',
             batch_size=8, max_tokens=0, threads=4):
    output = Path(output)
    if output.exists():
        raise FileExistsError('Report exists; choose a new report path')
    if split not in ('validation', 'test') or batch_size <= 0 or max_tokens < 0 or threads <= 0:
        raise ValueError('Invalid held-out evaluation settings')
    torch.set_num_threads(threads)
    device = select_device(device_name)
    checkpoint, model, tokenizer = load_checkpoint(checkpoint_path, device)
    manifest, prepared_tokenizer, datasets = load_bundle(data_path, checkpoint['config'], (split,))
    if checkpoint['dataset_id'] != manifest['dataset_id'] or tokenizer.digest != prepared_tokenizer.digest:
        raise ValueError('Checkpoint and evaluation dataset differ')
    result = validation_loss(model, datasets[split], batch_size, device, max_tokens)
    report = {
        'schema_version': 1, 'kind': 'lm-evaluation', 'split': split,
        'dataset_id': manifest['dataset_id'], 'checkpoint_sha256': file_hash(checkpoint_path),
        'step': checkpoint['step'], 'device': str(device), 'torch_version': str(torch.__version__),
        'threads': threads, 'batch_size': batch_size, **result,
        'perplexity': math.exp(result['loss']) if result['loss'] < 700 else None,
        'partial': result['tokens'] < manifest['splits'][split]['targets'],
        'window_order': 'fixed-permutation-seed-0' if max_tokens else 'complete-source-order',
        'note': 'Teacher-forced next-token loss/perplexity, not candidate top-1 or host-app latency.',
    }
    write_json(output, report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--data', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--split', choices=('validation', 'test'), default='validation')
    parser.add_argument('--device', choices=('auto', 'cpu', 'mps', 'cuda'), default='mps')
    parser.add_argument('--batch-size', type=int, default=8)
    parser.add_argument('--max-tokens', type=int, default=0)
    parser.add_argument('--threads', type=int, default=4)
    args = parser.parse_args()
    print(json.dumps(evaluate(args.checkpoint, args.data, args.output, args.split, args.device,
                              args.batch_size, args.max_tokens, args.threads), indent=2))
