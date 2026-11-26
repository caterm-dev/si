"""Explicit tiny CPU workflow only; not the 15.6M model or real Qwen training."""

import argparse
import json
from pathlib import Path
import tempfile

def run(root):
    from .evaluate import evaluate
    from .export import export
    from .fixtures import SyntheticTeacher, fixture
    from .prepare import prepare_documents, prepare_pools
    from .teacher import cache_teacher
    from .train import train

    root = Path(root)
    pretrain, distill, provenance, documents, records = fixture(root / 'inputs')
    prepare_documents(pretrain, documents, provenance, root / 'lm')
    prepare_pools(pretrain, root / 'lm', records, provenance, root / 'pools')
    cache_teacher(pretrain, root / 'lm', root / 'pools', root / 'teacher', SyntheticTeacher())
    train(pretrain, root / 'lm', root / 'pretrain', 'cpu', max_steps=2, threads=2)
    train(distill, root / 'lm', root / 'distill', 'cpu', pools_path=root / 'teacher',
          init_checkpoint=root / 'pretrain/best.pt', max_steps=2, threads=2)
    report = evaluate(root / 'distill/best.pt', root / 'lm', root / 'pools',
                      root / 'ranking.json', device_name='cpu', threads=2)
    export(root / 'distill/best.pt', root / 'lm', root / 'export', root / 'teacher')
    return dict(kind='synthetic-smoke-only', ranking_queries=report['counts']['queries'],
                output=str(root), note='Tiny CPU student and synthetic teacher; no real corpus/Qwen was read.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Optional fresh directory; default is a deleted temporary directory')
    args = parser.parse_args()
    if args.output:
        if args.output.exists():
            raise FileExistsError('Choose a new smoke directory')
        args.output.mkdir(parents=True)
        result = run(args.output)
    else:
        with tempfile.TemporaryDirectory(prefix='si-student-smoke-') as root:
            result = run(root)
            result['output'] = 'temporary synthetic artifacts removed'
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
