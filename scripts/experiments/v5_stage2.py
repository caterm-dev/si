#!/usr/bin/env python3
"""Prepare and compare additional V5 features on the frozen stage-one development pools."""
import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess

from v5_probability_audit import ROOT, pipeline
from v5_score_ablation import INDICES, METRICS, NAMES, ROUNDS, SEEDS, evaluate_row, paired_records

VARIANTS = ('A', 'E', 'F', 'G', 'H')
EXTENSION_NAMES = [
    'lexical_delta_from_pool_max_bits', 'lexical_pool_rank', 'lexical_pool_percentile',
    'pool_candidate_count',
    'buffer_exact_english_word', 'buffer_complete_pinyin', 'buffer_pinyin_segmentation_count',
    'buffer_case_pattern', 'buffer_has_digit', 'buffer_has_period', 'buffer_has_underscore',
    'buffer_has_slash', 'english_completion_ratio',
]
EXTENSION_SLICES = {'A': slice(0, 0), 'E': slice(0, 4), 'F': slice(4, 12),
                    'G': slice(12, 13), 'H': slice(0, 13)}
LEXICAL_INDEX = INDICES['lexical_score_bits']
DIAGNOSTICS = ('ci', 'goon', 'cannot', 'youyige', 'go on')
RESOURCES = pipeline.DEFAULT_RESOURCES


def parse_csv(line):
    return [None if value == 'null' else float(value) for value in line.split(',')]


def csv_line(values):
    return ','.join('null' if value is None else str(value) for value in values)


def invoke(command, requests):
    return subprocess.run(command, input=requests, text=True, check=True,
                          stdout=subprocess.PIPE, timeout=600).stdout


def inspect(exporter, rows, manifest):
    command = [str(exporter), 'rank-features', str(RESOURCES / 'main.silex'), '--grams',
               str(RESOURCES / 'words.sigram'), '--v5', '--pinyin-paths']
    if manifest['model_correction_pool']:
        command.append('--model-correction-pool')
    if manifest['pinyin_correction']:
        command.append('--pinyin-correction')
    requests = ''.join('\t'.join([
        row['input'].encode().hex(), row['context'].encode().hex(), ','.join(row['languages']),
        str(int(row.get('context_available', bool(row['context'])))), pipeline.encode_preferences(row),
    ]) + '\n' for row in rows)
    lines = iter(invoke(command, requests).splitlines())
    si_names = pipeline.V5_LEXICAL_FEATURES
    if next(lines) != pipeline.V5_LEXICAL_SCHEMA + '\t' + ','.join(si_names):
        raise ValueError('Unexpected isolated CLI schema')
    result = []
    for row in rows:
        candidates, details = [], {}
        for line in lines:
            if line.startswith('BUFFER\t'):
                buffer = parse_csv(line.split('\t')[1])
                break
            language, text_hex, features, ratio, edges, costs = line.split('\t')
            text = bytes.fromhex(text_hex).decode()
            values = parse_csv(features)
            if len(values) != len(si_names):
                raise ValueError('Unexpected isolated CLI candidate width')
            candidates.append({'language': language, 'text': text, 'features': values,
                               'label': int(text in row['references'])})
            words = [edge.split(':', 1) for edge in edges.split(',')]
            costs = dict(zip(('unigram_bits', 'internal_gram_adjustment_bits', 'token_cost_bits',
                              'language_cost_bits', 'spelling_cost_bits'), map(float, costs.split(',')), strict=True))
            details[language, text] = {'english_completion_ratio': float(ratio), **costs,
                                       'edges': [{'word': bytes.fromhex(word).decode(), 'log2_p': float(logp)}
                                                 for word, logp in words]}
        else:
            raise ValueError('Missing isolated CLI buffer line')
        marker, total, paths = next(lines).split('\t')
        if marker != 'END' or len(candidates) != min(int(total), 64) or len(details) != len(candidates):
            raise ValueError('Invalid isolated CLI group')
        exported = {**row, 'candidates': candidates, 'total_eligible': int(total),
                    'model_syllable_paths': paths.split('|') if paths else []}
        result.append((exported, buffer, details))
    if next(lines, None) is not None:
        raise ValueError('Unexpected isolated CLI output after groups')
    return result


def enrich(binary, groups):
    requests = ''.join('\t'.join(map(csv_line, group)) + '\n' for group in groups)
    lines = invoke([str(binary), 'enrich'], requests).splitlines()
    if not lines or lines[0].split(',') != EXTENSION_NAMES:
        raise ValueError('Unexpected V5 extension feature order')
    result = [[parse_csv(candidate) for candidate in line.split(';')] if line else []
              for line in lines[1:]]
    for (_, lexical, _), values in zip(groups, result, strict=True):
        if len(lexical) != len(values) or any(len(row) != len(EXTENSION_NAMES) for row in values):
            raise ValueError('Invalid enriched group width')
    return result


def append_extras(binary, groups):
    inputs = []
    for row, buffer, details in groups:
        lexical = [c['features'][LEXICAL_INDEX] for c in row['candidates']]
        ratios = [details.get((c['language'], c['text']), {}).get('english_completion_ratio', 1.0)
                  for c in row['candidates']]
        inputs.append((buffer, lexical, ratios))
    result = []
    for (row, _, _), extras in zip(groups, enrich(binary, inputs), strict=True):
        candidates = [{**c, 'features': [*c['features'], *extra]}
                      for c, extra in zip(row['candidates'], extras, strict=True)]
        result.append({**row, 'candidates': candidates})
    return result


def prepare(args):
    splits, manifest = pipeline.load_bundle(args.bundle)
    prepared = splits[0] + splits[1]
    lexicon = RESOURCES / 'main.silex'
    grams = RESOURCES / 'words.sigram'
    assets = {'lexicon': lexicon, 'grams': grams, 'pinyin_model': args.pinyin_model,
              'reranker_model': args.reranker_model}
    if any(pipeline.sha(path) != manifest['resources'][name] for name, path in assets.items()):
        raise ValueError('Expected the original training resources')
    if manifest['personal_state']['user_resources_supplied']:
        raise ValueError('Expected the original no-user training resources')
    exporter = args.rust / 'si-cli'
    pool_cli = args.rust / 'v5-pool-features'
    groups = []
    for frozen, (exported, buffer, traces) in zip(prepared, inspect(exporter, prepared, manifest), strict=True):
        original = [{**c, 'features': c['features'][:55]} for c in frozen['candidates']
                    if c['features'][INDICES['from_si_engine']]]
        if (original != exported['candidates'] or frozen['model_syllable_paths'] != exported['model_syllable_paths']
                or exported['total_eligible'] != frozen['total_eligible']):
            raise ValueError(f'The stage-one SI pool or feature values changed for {frozen["id"]}')
        groups.append((frozen, buffer, traces))
    print(f'Verified all {len(groups)} stage-one pools before feature enrichment', flush=True)
    train = append_extras(pool_cli, groups)

    models = pipeline.neural_features.NeuralModels(args.pinyin_model, args.reranker_model,
                                                   manifest['neural_models']['device'],
                                                   manifest['neural_models']['beam_size'])
    diagnostic_queries = [row for row in pipeline.read_queries(args.diagnostic) if row['input'] in DIAGNOSTICS]
    training_keys = {pipeline.normalized(row['input']) for row in prepared}
    if ({row['input'] for row in diagnostic_queries} != set(DIAGNOSTICS)
            or any(pipeline.normalized(row['input']) in training_keys for row in diagnostic_queries)):
        raise ValueError('Missing diagnostic inputs or overlap with training')
    diagnostic_rows = inspect(exporter, diagnostic_queries, manifest)
    diagnostic = append_extras(pool_cli, [
        (pipeline.neural_features.merge_row(row, pipeline.V5_LEXICAL_FEATURES, models.generate, models.score),
         buffer, trace) for row, buffer, trace in diagnostic_rows
    ])
    cannot = next((row, trace) for row, _, trace in diagnostic_rows if row['input'] == 'cannot')
    paths = {}
    for text in ('cannot', 'can not'):
        row, trace = cannot
        candidate = next(c for c in row['candidates'] if c['text'] == text and c['language'] == 'en')
        paths[text] = {'lexical_score_bits': candidate['features'][LEXICAL_INDEX], **trace['en', text]}
    pipeline.write_json(args.output, {
        'base_bundle_manifest_sha256': pipeline.sha(args.bundle / 'manifest.json'),
        'diagnostic_sha256': pipeline.sha(args.diagnostic), 'names': NAMES + EXTENSION_NAMES,
        'training': train, 'diagnostic': diagnostic, 'cannot_paths': paths,
    })


def names(variant):
    return NAMES + EXTENSION_NAMES[EXTENSION_SLICES[variant]]


def matrix(values, variant):
    import numpy as np

    sl = EXTENSION_SLICES[variant]
    return np.asarray([[*row[:len(NAMES)], *row[len(NAMES):][sl]] for row in values], dtype=float)


def fit(rows, variant, params):
    import lightgbm as lgb

    values, labels, groups = pipeline.training_matrix(rows)
    columns = names(variant)
    categorical = [key for key in ('candidate_language', 'buffer_case_pattern') if key in columns]
    dataset = lgb.Dataset(matrix(values, variant), label=labels, group=groups,
                          feature_name=columns, categorical_feature=categorical)
    return lgb.train(params, dataset, num_boost_round=ROUNDS)


def predict(model, rows, variant):
    if model.feature_name() != names(variant):
        raise ValueError('Unexpected model feature order')
    values = [c['features'] for row in rows for c in row['candidates']]
    scores = iter(model.predict(matrix(values, variant), raw_score=True, num_threads=1))
    output = []
    for row in rows:
        scored = [(candidate, float(next(scores))) for candidate in row['candidates']]
        if any(not math.isfinite(score) for _, score in scored):
            raise ValueError('Nonfinite model score')
        output.append(sorted(scored, key=lambda item: -item[1]))
    if next(scores, None) is not None:
        raise ValueError('Unexpected extra predictions')
    return output


def compare(args):
    import lightgbm as lgb
    import numpy as np

    data = json.loads(args.features.read_text())
    original_report = json.loads((args.stage1 / 'report.json').read_text())
    folds = json.loads((args.stage1 / 'folds.json').read_text())
    prior_results = json.loads((args.stage1 / 'out-of-fold.json').read_text())
    if (data['names'] != NAMES + EXTENSION_NAMES
            or data['base_bundle_manifest_sha256'] != original_report['bundle_manifest_sha256']
            or original_report['rounds'] != ROUNDS):
        raise ValueError('Expected the stage-one baseline and complete extension schema')
    rows = data['training']
    params = original_report['baseline_params']
    args.output.mkdir(parents=True, exist_ok=False)
    results = {}
    for seed in SEEDS:
        seed_results = {variant: {} for variant in VARIANTS}
        for fold in map(set, folds[str(seed)]):
            train = [row for row in rows if row['id'] not in fold]
            held = [row for row in rows if row['id'] in fold]
            for variant in VARIANTS:
                model = fit(train, variant, {**params, 'seed': seed})
                pools = predict(model, held, variant)
                seed_results[variant].update({row['id']: evaluate_row(pool)
                                              for row, pool in zip(held, pools, strict=True)})
        if seed_results['A'] != prior_results[str(seed)]['A']:
            raise ValueError(f'Stage-one out-of-fold baseline drifted at seed {seed}')
        results[seed] = seed_results
        print(f'Completed seed {seed}; A matches stage one', flush=True)

    aggregate = {}
    for variant in VARIANTS:
        summary = {}
        for metric in METRICS:
            values = [statistics.fmean(row[metric] for row in results[seed][variant].values()) for seed in SEEDS]
            summary[metric] = {'mean': statistics.fmean(values), 'sample_std': statistics.stdev(values),
                               'per_seed': values}
            if variant != 'A':
                summary[metric]['delta_vs_A'] = summary[metric]['mean'] - aggregate['A'][metric]['mean']
        aggregate[variant] = summary
    paired = paired_records(rows, results, args.output, variants=VARIANTS[1:])
    pipeline.write_json(args.output / 'out-of-fold.json', results)
    pipeline.write_json(args.output / 'report.json', {
        'queries': len(rows), 'seeds': SEEDS, 'rounds': ROUNDS, 'params': params,
        'folds_sha256': pipeline.sha(args.stage1 / 'folds.json'),
        'features_sha256': pipeline.sha(args.features), 'stage_one_A_exact': True,
        'feature_counts': {variant: len(names(variant)) for variant in VARIANTS},
        'metrics': aggregate, 'paired': paired,
    })

    refit = args.output / 'refit'
    refit.mkdir()
    diagnostic = data['diagnostic']
    cases = [{'input': row['input'], 'candidate_count': len(row['candidates']), 'variants': {}}
             for row in diagnostic]
    from v5_eval import candidate_source
    for variant in VARIANTS:
        model = fit(rows, variant, {**params, 'seed': SEEDS[0]})
        model.save_model(str(refit / f'{variant}.txt'))
        for case, pool in zip(cases, predict(model, diagnostic, variant), strict=True):
            case['variants'][variant] = [
                {'text': candidate['text'], 'language': candidate['language'], 'score': score,
                 'source': candidate_source(candidate['features'])} for candidate, score in pool[:4]
            ]
    pipeline.write_json(args.output / 'diagnostic.json', cases)
    cannot = next(row for row in diagnostic if row['input'] == 'cannot')
    compared = [next(candidate for candidate in cannot['candidates']
                     if candidate['language'] == 'en' and candidate['text'] == text)
                for text in ('cannot', 'can not')]
    model = lgb.Booster(model_file=str(refit / 'A.txt'))
    values = matrix([candidate['features'] for candidate in compared], 'A')
    scores = model.predict(values, raw_score=True, num_threads=1)
    contributions = model.predict(values, pred_contrib=True, num_threads=1)
    delta = contributions[1] - contributions[0]
    np.testing.assert_allclose(delta.sum(), scores[1] - scores[0], atol=1e-12, rtol=0)
    paths = data['cannot_paths']
    for candidate, score in zip(compared, scores, strict=True):
        paths[candidate['text']]['A_model_score'] = float(score)
    pipeline.write_json(args.output / 'cannot.json', {
        'paths': paths,
        'A_contribution_delta_can_not_minus_cannot': dict(sorted(zip(NAMES, map(float, delta[:-1])),
                                                                key=lambda item: -abs(item[1]))),
    })


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--rust', type=Path, required=True)
    prep.add_argument('--bundle', type=Path, required=True)
    prep.add_argument('--diagnostic', type=Path, default=ROOT / 'eval/ranking/diagnostic-dev.jsonl')
    prep.add_argument('--pinyin-model', type=Path,
                      default=ROOT / 'llm/pinyin_to_text/runs/small-pinyin-syllable-100k-v1/best.pt')
    prep.add_argument('--reranker-model', type=Path,
                      default=ROOT / 'llm/reranker_small/runs/small-chat-v2/best.pt')
    prep.add_argument('--output', type=Path, required=True)
    cv = sub.add_parser('compare')
    cv.add_argument('--features', type=Path, required=True)
    cv.add_argument('--stage1', type=Path, required=True)
    cv.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args)
    else:
        compare(args)


if __name__ == '__main__':
    main()
