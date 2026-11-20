"""Export the fitted single-output LambdaRank trees and check Rust prediction parity."""

import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile

if __package__:
    from .pipeline import MERGED_SCHEMAS, SCHEMAS, load_bundle, sha
else:
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


def calibrate_corrections(validation, features, predictions):
    corrected = features.index('is_corrected')
    from_si = features.index('from_si_engine')
    clean, typos = [], []
    predictions = iter(predictions)
    for row in validation:
        scored = [(c, float(next(predictions))) for c in row['candidates']]
        ordinary = max((score for c, score in scored
                        if c['features'][from_si] and not c['features'][corrected]), default=0.0)
        corrections = [(score - ordinary, c['label'])
                       for c, score in scored if c['features'][corrected]]
        if row['category'] == 'pinyin-correction':
            typos.append(max((gap for gap, label in corrections if label), default=-math.inf))
        else:
            clean.append(max((gap for gap, _ in corrections), default=-math.inf))
    clean_gaps = sorted((gap for gap in clean if math.isfinite(gap)), reverse=True)
    positive_gaps = [gap for gap in typos if math.isfinite(gap)]
    if not clean_gaps or not positive_gaps:
        raise ValueError('Correction calibration needs both clean suggestions and reachable intended corrections')
    margins, report = {}, {}
    for mode, allowed in [('conservative', 0), ('higher_recall', len(clean) // 20)]:
        margin = (clean_gaps[allowed] if allowed < len(clean_gaps)
                  else math.nextafter(min(clean_gaps + positive_gaps), -math.inf))
        margins[mode] = margin
        report[mode] = {'clean_with_suggestion': sum(gap > margin for gap in clean),
                        'typos_with_intended_suggestion': sum(gap > margin for gap in typos)}
    return margins, {'clean_queries': len(clean), 'typo_queries': len(typos),
                     'typos_in_pool': len(positive_gaps), **report}


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
    calibration = {}
    if manifest.get('model_correction_pool'):
        train_count = sum(len(row['candidates']) for row in train)
        document['correction_margins'], calibration = calibrate_corrections(
            validation, features, expected[train_count:])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent, prefix='.si-lambdarank-') as tmp:
        export = Path(tmp) / 'lambdarank.json'
        export.write_text(json.dumps(document, allow_nan=False) + '\n')
        result = subprocess.run([str(args.binary), 'score', str(export)], check=True, text=True,
                                input=''.join(json.dumps(row) + '\n' for row in rows), capture_output=True)
        actual = np.array([json.loads(line) for line in result.stdout.splitlines()])
        np.testing.assert_allclose(actual, expected, rtol=0, atol=1e-12)
        export.rename(args.output)
    report = {'candidates': len(rows), 'max_absolute_error': float(abs(actual - expected).max())}
    if calibration:
        report['correction_calibration'] = calibration
    print(json.dumps(report))


if __name__ == '__main__':
    main()
