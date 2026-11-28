"""Verified, indexed candidate pools; requested splits alone are opened."""

import json
from pathlib import Path

import numpy as np

from llm.pinyin_to_text.common import file_hash, fingerprint, read_json
from .settings import APP_PROTOCOL, SEQUENCE_KD, SPLITS, score_mapping, training_objective


def manifest_at(root, kind):
    root = Path(root)
    manifest = read_json(root / 'manifest.json')
    if (manifest.get('schema_version') != 1 or manifest.get('kind') != kind
            or fingerprint({k: v for k, v in manifest.items() if k != 'dataset_id'}) != manifest['dataset_id']):
        raise ValueError('Invalid dataset manifest identity')
    return manifest


def checked_file(root, manifest, name):
    root = Path(root).resolve()
    path = (root / name).resolve()
    if Path(name).is_absolute() or not path.is_relative_to(root) or file_hash(path) != manifest['files'][name]:
        raise ValueError('Dataset file modified or unsafe: ' + name)
    return path


class PoolWriter:
    def __init__(self, root, split):
        self.text = (root / f'{split}.jsonl').open('wb')
        self.index = (root / f'{split}.index.bin').open('wb')
        self.count = 0

    def append(self, row):
        content = (json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n').encode('utf-8')
        self.index.write(np.asarray([self.text.tell(), len(content)], dtype='<u8').tobytes())
        self.text.write(content)
        self.count += 1

    def close(self):
        self.text.close()
        self.index.close()


class Pools:
    def __init__(self, root, manifest, split):
        text = checked_file(root, manifest, f'{split}.jsonl')
        index = checked_file(root, manifest, f'{split}.index.bin')
        self.text = np.memmap(text, dtype='u1', mode='r')
        self.index = np.memmap(index, dtype='<u8', mode='r').reshape(-1, 2)
        if (len(self.index) != manifest['splits'][split]['pools'] or np.any(self.index[:, 1] == 0)
                or np.any(self.index[:, 0] + self.index[:, 1] > len(self.text))):
            raise ValueError('Invalid candidate-pool index')

    def __len__(self):
        return len(self.index)

    def __getitem__(self, index):
        start, length = map(int, self.index[index])
        return json.loads(self.text[start:start + length].tobytes())


def load_pools(root, config, lm_manifest, tokenizer, splits, *, scored):
    manifest = manifest_at(root, 'si-student-pools')
    expected = {k: config['scoring'][k] for k in ('max_candidates', 'context_tokens', 'candidate_tokens')}
    if (manifest['lm_dataset_id'] != lm_manifest['dataset_id']
            or manifest['tokenizer_digest'] != tokenizer.digest or manifest['limits'] != expected
            or bool(manifest.get('teacher')) != scored):
        raise ValueError('Pool tokenizer, parent dataset, limits or teacher stage mismatch')
    if manifest.get('score_mapping', {'protocol': 'mean-logp-v1'}) != score_mapping(config):
        raise ValueError('Candidate-cache score protocol differs from student scoring')
    if training_objective(config) == SEQUENCE_KD and manifest.get('training_objective') != SEQUENCE_KD:
        raise ValueError('Candidate sequence KL requires its verified active-pool derivative')
    if not splits or any(s not in SPLITS for s in splits):
        raise ValueError('Select explicit candidate-pool splits')
    return manifest, {s: Pools(Path(root), manifest, s) for s in splits}
