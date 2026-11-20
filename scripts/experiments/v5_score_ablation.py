#!/usr/bin/env python3
"""Run fixed-round, grouped V5 score ablations on prepared train and validation pools."""
import argparse
from collections import Counter, defaultdict
import csv
from fractions import Fraction
import json
import math
from pathlib import Path
import random
import statistics

from v5_probability_audit import LEXICAL, LIMIT, PURE, pipeline, pure_probability

VARIANTS = ('A', 'B', 'C', 'D')
SEEDS = (17, 23, 41, 59, 73)
FOLDS = 5
ROUNDS = 50
NAMES = pipeline.V5_FEATURES
INDICES = {name: index for index, name in enumerate(NAMES)}
METRICS = ('top1', 'top4', 'ndcg4', 'mrr')


def feature_names(variant):
    if variant == 'A':
        return NAMES
    if variant == 'B':
        return [name for name in NAMES if name != LEXICAL]
    if variant == 'C':
        return [PURE if name == LEXICAL else name for name in NAMES]
    if variant == 'D':
        return [*NAMES, PURE]
    raise ValueError(f'Unknown variant {variant}')


def project(features, variant):
    if variant == 'A':
        return features
    index = INDICES[LEXICAL]
    if variant == 'B':
        return features[:index] + features[index + 1:]
    pure = pure_probability(features, INDICES)
    if variant == 'C':
        return [*features[:index], pure, *features[index + 1:]]
    if variant == 'D':
        return [*features, pure]
    raise ValueError(f'Unknown variant {variant}')


def make_folds(rows, seed):
    groups = defaultdict(list)
    for row in rows:
        groups[pipeline.normalized(row['input'])].append(row['id'])
    shuffled = list(groups.values())
    random.Random(seed).shuffle(shuffled)
    folds = [[] for _ in range(FOLDS)]
    for group in sorted(shuffled, key=len, reverse=True):
        min(folds, key=len).extend(group)
    return [set(fold) for fold in folds]


def fit(rows, variant, params):
    import lightgbm as lgb
    import numpy as np

    features, labels, groups = pipeline.training_matrix(rows)
    names = feature_names(variant)
    matrix = np.asarray([project(row, variant) for row in features], dtype=float)
    train = lgb.Dataset(matrix, label=labels, group=groups, feature_name=names,
                        categorical_feature=['candidate_language'])
    return lgb.train(params, train, num_boost_round=ROUNDS), len(groups)


def rank_pools(model, rows, variant):
    import numpy as np

    names = feature_names(variant)
    if model.feature_name() != names:
        raise ValueError(f'Model feature names differ from variant {variant}')
    candidates = [c for row in rows for c in row['candidates']]
    if candidates:
        matrix = np.asarray([project(c['features'], variant) for c in candidates], dtype=float)
        scores = model.predict(matrix, raw_score=True, num_threads=1)
        if not np.isfinite(scores).all():
            raise ValueError('Nonfinite prediction')
    else:
        scores = []
    cursor = 0
    result = []
    for row in rows:
        pool = row['candidates']
        scored = zip(pool, scores[cursor:cursor + len(pool)], strict=True)
        result.append(sorted(scored, key=lambda item: -item[1]))
        cursor += len(pool)
    return result


def evaluate_row(scored):
    labels = [candidate['label'] for candidate, _ in scored]
    rank = next((index for index, label in enumerate(labels, 1) if label), None)
    dcg = sum(label / math.log2(index + 2) for index, label in enumerate(labels[:4]))
    ideal = sum(1 / math.log2(index + 2) for index in range(min(4, sum(labels))))
    return {
        'rank': rank, 'top1': float(rank == 1), 'top4': float(rank is not None and rank <= 4),
        'ndcg4': dcg / ideal if ideal else 0.0, 'mrr': 1 / rank if rank else 0.0,
    }


def recall(rows):
    by_category, by_reference_type = defaultdict(list), defaultdict(list)
    for row in rows:
        by_category[row['category']].append(row)
        types = {pipeline.neural_features.candidate_language(text) for text in row['references']}
        label = next(iter(types)) if len(types) == 1 else None
        by_reference_type[label or 'unclassified'].append(row)

    def summary(pool):
        hits = sum(any(candidate['label'] for candidate in row['candidates']) for row in pool)
        return {'hits': hits, 'queries': len(pool), 'recall': hits / len(pool)}

    return {'overall': summary(rows),
            'by_category': {key: summary(value) for key, value in sorted(by_category.items())},
            'by_reference_type': {key: summary(value) for key, value in sorted(by_reference_type.items())}}


def reciprocal(rank):
    return Fraction(1, rank) if rank is not None else Fraction(0)


def comparison(value, baseline):
    return 'better' if value > baseline else 'worse' if value < baseline else 'same'


def paired_records(rows, results, output, variants=VARIANTS[1:]):
    counts = {}
    for variant in variants:
        per_query = Counter()
        per_seed = {seed: Counter() for seed in SEEDS}
        with (output / f'{variant}-vs-A.tsv').open('x', newline='') as stream:
            writer = csv.writer(stream, delimiter='\t')
            writer.writerow(('id', 'input', 'context', 'category', 'references', 'A_ranks', 'variant_ranks',
                             'A_mean_mrr', 'variant_mean_mrr', 'label', 'per_seed_labels'))
            for row in rows:
                ranks = {key: [results[seed][key][row['id']]['rank'] for seed in SEEDS]
                         for key in ('A', variant)}
                averages = {key: sum(map(reciprocal, values)) / len(SEEDS) for key, values in ranks.items()}
                labels = []
                for seed, baseline, value in zip(SEEDS, ranks['A'], ranks[variant], strict=True):
                    label = comparison(reciprocal(value), reciprocal(baseline))
                    per_seed[seed][label] += 1
                    labels.append(label)
                overall = comparison(averages[variant], averages['A'])
                per_query[overall] += 1
                if any(label != 'same' for label in labels):
                    writer.writerow((row['id'], row['input'], row['context'], row['category'],
                                     ' / '.join(row['references']), json.dumps(ranks['A']),
                                     json.dumps(ranks[variant]), float(averages['A']),
                                     float(averages[variant]), overall, ','.join(labels)))
        counts[variant] = {'by_query_mean_reciprocal_rank': dict(per_query),
                           'per_seed_rank_comparison': {seed: dict(value) for seed, value in per_seed.items()}}
    return counts


def run(args):
    import lightgbm as lgb
    import numpy as np

    audit = json.loads(args.audit.read_text())
    if not audit['passed'] or audit['samples'] != 300 or audit['max_error_bits'] > LIMIT:
        raise ValueError('A passing 300-path probability audit is required')
    splits, manifest = pipeline.load_bundle(args.bundle)
    run = json.loads(args.baseline_run.read_text())
    bundle_sha = pipeline.sha(args.bundle / 'manifest.json')
    if (manifest['features'] != NAMES or run['features'] != NAMES
            or run['bundle_manifest_sha256'] != bundle_sha):
        raise ValueError('Expected the exact V5 bundle and corresponding baseline run')
    rows = splits[0] + splits[1]
    if [len(split) for split in splits] != [120, 65] or len({row['id'] for row in rows}) != len(rows):
        raise ValueError('Expected the original 185 distinct query IDs')
    args.output.mkdir(parents=True, exist_ok=False)
    all_results, folds_by_seed, group_counts = {}, {}, {}
    for seed in SEEDS:
        all_results[seed] = {variant: {} for variant in VARIANTS}
        group_counts[seed] = []
        folds = make_folds(rows, seed)
        folds_by_seed[seed] = [sorted(fold) for fold in folds]
        for fold in folds:
            train = [row for row in rows if row['id'] not in fold]
            held = [row for row in rows if row['id'] in fold]
            fold_counts = []
            for variant in VARIANTS:
                model, groups = fit(train, variant, {**run['params'], 'seed': seed})
                fold_counts.append(groups)
                scored = rank_pools(model, held, variant)
                all_results[seed][variant].update({row['id']: evaluate_row(pool)
                                                   for row, pool in zip(held, scored, strict=True)})
            if len(set(fold_counts)) != 1:
                raise ValueError('Variant training query counts differ')
            group_counts[seed].append(fold_counts[0])
        if any(set(scores) != {row['id'] for row in rows} for scores in all_results[seed].values()):
            raise ValueError('Incomplete out-of-fold predictions')
        print(f'Completed seed {seed}', flush=True)

    aggregate = {}
    for variant in VARIANTS:
        summary = {}
        for name in METRICS:
            values = [statistics.fmean(r[name] for r in all_results[seed][variant].values()) for seed in SEEDS]
            summary[name] = {'mean': statistics.fmean(values), 'sample_std': statistics.stdev(values),
                             'per_seed': values}
            if variant != 'A':
                summary[name]['delta_vs_A'] = summary[name]['mean'] - aggregate['A'][name]['mean']
        aggregate[variant] = summary
    pipeline.write_json(args.output / 'out-of-fold.json', all_results)
    pipeline.write_json(args.output / 'folds.json', folds_by_seed)
    paired = paired_records(rows, all_results, args.output)
    report = {'queries': len(rows), 'seeds': SEEDS, 'folds': FOLDS, 'rounds': ROUNDS,
              'grouping': 'all candidates and normalized spelling variants stay in the same fold',
              'train_informative_groups_by_seed_fold': group_counts, 'baseline_params': run['params'],
              'bundle_manifest_sha256': bundle_sha, 'probability_audit_sha256': pipeline.sha(args.audit),
              'lightgbm_version': lgb.__version__, 'numpy_version': np.__version__,
              'metrics': aggregate, 'paired': paired, 'recall': recall(rows)}
    pipeline.write_json(args.output / 'report.json', report)

    model_dir = args.output / 'refit'
    model_dir.mkdir()
    for variant in VARIANTS:
        model, groups = fit(rows, variant, {**run['params'], 'seed': SEEDS[0]})
        model.save_model(str(model_dir / f'{variant}.txt'))
    pipeline.write_json(model_dir / 'manifest.json', {
        'seed': SEEDS[0], 'rounds': ROUNDS, 'queries': len(rows), 'informative_queries': groups,
        'bundle_manifest_sha256': bundle_sha,
        'models': {variant: pipeline.sha(model_dir / f'{variant}.txt') for variant in VARIANTS},
    })
    print(json.dumps(aggregate, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--baseline-run', type=Path, required=True)
    parser.add_argument('--audit', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    run(parser.parse_args())
