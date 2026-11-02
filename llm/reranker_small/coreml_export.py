"""Stage an offline, FP32 Core ML candidate scorer for the local macOS app.

Requires coremltools 8.3.0 in addition to the pinned training environment.
No private text, history or learning archives are read.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import numpy as np
import torch
from torch import nn

from .export import export
from .runtime import load_checkpoint, rank_candidates
from .settings import file_hash, write_json


class CandidateScorer(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, tokens, targets, mask):
        probabilities = self.model(tokens).log_softmax(-1)
        picked = probabilities.gather(-1, targets.long().unsqueeze(-1)).squeeze(-1)
        return (picked * mask).sum(-1)


def convert(checkpoint, data, destination):
    import coremltools as ct

    torch.set_num_threads(4)
    payload, model, tokenizer = load_checkpoint(checkpoint, torch.device('cpu'))
    if destination.exists() and any(p.name != 'README.md' for p in destination.iterdir()):
        raise ValueError('Use a new output directory; existing model artifacts are never overwritten')
    with tempfile.TemporaryDirectory(prefix='si-coreml-') as temporary:
        root = Path(temporary)
        export(checkpoint, data, root / 'inference')
        wrapper = CandidateScorer(model).eval()
        tokens = torch.full((4, 16), 4, dtype=torch.int32)
        mask = torch.ones((4, 16), dtype=torch.float32)
        traced = torch.jit.trace(wrapper, (tokens, tokens, mask))
        length = ct.RangeDim(lower_bound=1, upper_bound=256, default=16)
        converted = ct.convert(
            traced, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS14,
            compute_precision=ct.precision.FLOAT32,
            inputs=[ct.TensorType(name='tokens', shape=(4, length), dtype=np.int32),
                    ct.TensorType(name='targets', shape=(4, length), dtype=np.int32),
                    ct.TensorType(name='mask', shape=(4, length), dtype=np.float32)],
            outputs=[ct.TensorType(name='scores')], compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        # Validate real scoring, multiple lengths and byte fallback before staging.
        fixtures = ['我们开会', '我们开慧', 'Swift API', '🙂𠀀']
        expected = rank_candidates(model, tokenizer, '', fixtures, torch.device('cpu'))['scores']
        maximum_error = 0.0
        for texts in [fixtures, ['是', '时', '事', '十'], ['我' * 256] * 4]:
            encoded = [tokenizer.encode(text)[1:-1] for text in texts]
            width = max(map(len, encoded))
            values = np.full((4, width), 4, dtype=np.int32)
            targets = np.full((4, width), 4, dtype=np.int32)
            masks = np.zeros((4, width), dtype=np.float32)
            for index, row in enumerate(encoded):
                values[index, :len(row)] = [1, *row[:-1]]
                targets[index, :len(row)] = row
                masks[index, :len(row)] = 1
            actual = converted.predict({'tokens': values, 'targets': targets, 'mask': masks})['scores']
            reference = rank_candidates(model, tokenizer, '', texts, torch.device('cpu'))['scores']
            np.testing.assert_allclose(actual, reference, atol=0.005, rtol=0.0001)
            maximum_error = max(maximum_error, float(np.max(np.abs(actual - reference))))
        package = root / 'SmallReranker.mlpackage'
        converted.save(str(package))
        subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), str(root)], check=True)
        inference = root / 'inference'
        (inference / 'model.pt').unlink()
        shutil.copytree(root / 'SmallReranker.mlmodelc', inference / 'SmallReranker.mlmodelc')
        write_json(inference / 'runtime.json', {
            'schemaVersion': 1, 'contextLength': 256, 'batchSize': 4,
            'checkpointSHA256': file_hash(checkpoint), 'checkpointStep': payload['step'],
            'tokenizerSHA256': file_hash(inference / 'tokenizer.json'),
            'coremltools': ct.__version__, 'precision': 'float32',
            'validationMaximumAbsoluteError': maximum_error,
            'validationScores': expected,
        })
        attribution = json.loads((inference / 'manifest.json').read_text())
        attribution['kind'] = 'si-character-lm-coreml-inference'
        attribution['note'] = ('Locally staged FP32 Core ML scorer. Source data terms remain separate; '
                               'no blanket model-weight license is assigned.')
        attribution['files'] = {str(path.relative_to(inference)): file_hash(path)
                                for path in sorted(inference.rglob('*'))
                                if path.is_file() and path != inference / 'manifest.json'}
        write_json(inference / 'manifest.json', attribution)
        destination.mkdir(parents=True, exist_ok=True)
        for source in inference.iterdir():
            target = destination / source.name
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)
        print(json.dumps({'checkpoint_step': payload['step'], 'maximum_absolute_error': maximum_error,
                          'destination': str(destination)}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    convert(args.checkpoint, args.data, args.output)
