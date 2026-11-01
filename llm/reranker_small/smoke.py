"""Explicit four-step tiny CPU workflow; never train the configured 7.4M model."""

import argparse
import json
from pathlib import Path

import torch

from .benchmark import benchmark
from .evaluate import evaluate
from .export import export
from .fixtures import fixture
from .prepare import prepare
from .runtime import load_checkpoint, rank_candidates, select_device
from .settings import ROOT, write_json
from .train import train


def smoke(output, device_name='cpu'):
    output = Path(output)
    if output.exists():
        raise FileExistsError('Smoke output exists; choose a new directory')
    output.mkdir(parents=True)
    config, lock, raw = fixture(output / 'fixtures')
    manifest = prepare(config, output / 'data', lock, raw)
    train(config, output / 'data', output / 'run', device_name, max_steps=2, threads=2)
    train(config, output / 'data', output / 'run', device_name, resume=True, max_steps=4, threads=2)
    checkpoint = output / 'run/best.pt'
    for split in ('validation', 'test'):
        evaluate(checkpoint, output / 'data', output / f'{split}.json', split, device_name,
                 batch_size=2, max_tokens=128, threads=2)
    benchmark(checkpoint, ROOT / 'benchmarks/example.jsonl', ROOT / 'benchmarks/example.provenance.json',
              output / 'ranking.json', device_name, threads=2)
    export(checkpoint, output / 'data', output / 'export')
    _, model, tokenizer = load_checkpoint(output / 'export/model.pt', select_device(device_name))
    result = rank_candidates(model, tokenizer, '今天下午，', ['中文测试', '中文侧试'], select_device(device_name))
    assert sorted(result['order']) == [0, 1]
    summary = {'status': 'passed', 'dataset_id': manifest['dataset_id'], 'training_steps': 4,
               'device': device_name, 'note': 'Tiny synthetic workflow, not formal baseline training or quality evidence.'}
    write_json(output / 'summary.json', summary)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=('cpu', 'mps', 'cuda'), default='cpu')
    args = parser.parse_args()
    print(json.dumps(smoke(args.output, args.device), indent=2))
