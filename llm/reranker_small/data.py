"""Verified read-only token windows; loading train never opens the test split."""

from pathlib import Path

import numpy as np
import torch

from .settings import SPLITS, file_hash, fingerprint, read_json
from .tokenizer import PAD, Tokenizer


def load_bundle(path, config, splits):
    path = Path(path)
    manifest = read_json(path / 'manifest.json')
    if (manifest.get('schema_version') != 1 or manifest.get('kind') != 'si-character-lm'
            or fingerprint({key: value for key, value in manifest.items() if key != 'dataset_id'}) != manifest['dataset_id']):
        raise ValueError('Invalid character-LM dataset identity')
    if manifest['model_limits'] != {key: config['model'][key] for key in ('vocab_size', 'context')}:
        raise ValueError('Prepared context/vocabulary differs from the model')
    if not splits or any(split not in SPLITS for split in splits):
        raise ValueError('Select explicit train/validation/test splits')
    names = ['tokenizer.json'] + [f'{split}.{suffix}' for split in splits
                               for suffix in ('tokens.bin', 'windows.bin')]
    for name in names:
        if file_hash(path / name) != manifest['files'][name]:
            raise ValueError('Prepared file modified: ' + name)
    tokenizer = Tokenizer.load(path / 'tokenizer.json')
    if tokenizer.digest != manifest['tokenizer_digest']:
        raise ValueError('Tokenizer identity mismatch')
    datasets = {split: Windows(path, split, manifest['splits'][split], config['model']['context']) for split in splits}
    return manifest, tokenizer, datasets


class Windows:
    def __init__(self, root, split, counts, context):
        self.tokens = np.memmap(root / f'{split}.tokens.bin', dtype='<u2', mode='r')
        self.windows = np.memmap(root / f'{split}.windows.bin', dtype='<u8', mode='r').reshape(-1, 2)
        self.context = context
        if len(self.tokens) != counts['tokens'] or len(self.windows) != counts['windows']:
            raise ValueError('Prepared array shape mismatch')
        if (np.any(self.windows[:, 1] < 2) or np.any(self.windows[:, 1] > context + 1)
                or np.any(self.windows[:, 0] + self.windows[:, 1] > len(self.tokens))):
            raise ValueError('Invalid document window boundaries')

    def __len__(self):
        return len(self.windows)

    def target_count(self, indices):
        return sum(int(self.windows[index, 1]) - 1 for index in indices)

    def batch(self, indices, device):
        length = max(int(self.windows[index, 1]) for index in indices)
        values = np.full((len(indices), length), PAD, dtype=np.int64)
        for row, index in enumerate(indices):
            start, count = map(int, self.windows[index])
            values[row, :count] = self.tokens[start:start + count]
        tensor = torch.from_numpy(values).to(device)
        return tensor[:, :-1], tensor[:, 1:]
