"""Export the fitted single-output LambdaRank trees and check Rust prediction parity."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from pipeline import MERGED_SCHEMAS, SCHEMAS, load_bundle, sha


def node(tree):
    if 'leaf_value' in tree:
        return {'kind': 'leaf', 'value': tree['leaf_value']}
    result = {'feature': tree['split_feature'], 'left': node(tree['left_child']),
              'right': node(tree['right_child'])}
    if tree['decision_type'] == '<=':
        return dict(result, kind='numeric', threshold=tree['threshold'],
                    missing=tree['missing_type'], default_left=tree['default_left'])
    if tree['decision_type'] == '==':
        return dict(result, kind='categorical', categories=[int(x) for x in tree['threshold'].split('||')])
    raise ValueError('Unsupported split type')


def main():
    import lightgbm as lgb
    import numpy as np

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Choose a new model export path')
    model_path = args.run / 'model.txt'
    run = json.loads((args.run / 'run.json').read_text())
    (train, validation), manifest = load_bundle(args.bundle)
    schema = run['schema']
    features = SCHEMAS.get(schema)
    if (schema not in MERGED_SCHEMAS or manifest['schema'] != schema or run['features'] != features or
            run['bundle_manifest_sha256'] != sha(args.bundle / 'manifest.json') or
            run['model_sha256'] != sha(model_path)):
        raise ValueError('Expected the full neural run and its original bundle')
    model = lgb.Booster(model_file=str(model_path))
    graph = model.dump_model()
    if (graph['feature_names'] != features or graph['average_output'] or
            graph['num_tree_per_iteration'] != 1 or graph.get('objective') != 'lambdarank'):
        raise ValueError('Expected single-output LambdaRank trees')
    models = manifest['resources']
    document = {'schema': 1, 'feature_names': features,
                'training_model_sha256': run['model_sha256'],
                'pinyin_checkpoint_sha256': models['pinyin_model'],
                'reranker_checkpoint_sha256': models['reranker_model'],
                'beam_size': manifest['neural_models']['beam_size'],
                'trees': [node(t['tree_structure']) for t in graph['tree_info']]}
    rows = [c['features'] for row in train + validation for c in row['candidates']]
    expected = model.predict(np.asarray(rows, dtype=float), raw_score=True, num_threads=1)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent, prefix='.si-lambdarank-') as tmp:
        export = Path(tmp) / 'lambdarank.json'
        export.write_text(json.dumps(document, allow_nan=False) + '\n')
        result = subprocess.run([str(args.binary), 'score', str(export)], check=True, text=True,
                                input=''.join(json.dumps(row) + '\n' for row in rows), capture_output=True)
        actual = np.array([json.loads(line) for line in result.stdout.splitlines()])
        np.testing.assert_allclose(actual, expected, rtol=0, atol=1e-12)
        export.rename(args.output)
    print(json.dumps({'candidates': len(rows), 'max_absolute_error': float(abs(actual - expected).max())}))


if __name__ == '__main__':
    main()
