#!/usr/bin/env python3
"""Offline Rust-feature export, LightGBM LambdaRank training and evaluation."""
import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'eval/lambdarank'
SCHEMA = 'si-rank-features-v3'
V1_FEATURES = ['lexical_bits', 'context_bits', 'effective_bits', 'consumed_scalars',
            'output_scalars', 'lexical_tokens', 'bits_per_source_scalar',
            'bits_per_output_scalar', 'is_chinese', 'is_english', 'is_mixed', 'separator_count']


V2_GROUPS = {
    'score_components': ['unigram_bits', 'gram_adjustment_bits', 'token_cost_bits', 'language_cost_bits', 'spelling_cost_bits'],
    'gram_evidence': ['gram_hit_fraction', 'max_gram_order', 'gram_log_support', 'gram_model_available'],
    'context_evidence': ['context_available', 'context_history_words', 'context_matched', 'context_gram_order', 'context_log_support'],
    'path_structure': ['best_path_tokens', 'has_direct_match', 'single_character_tokens', 'min_token_scalars', 'max_token_scalars', 'language_switches'],
    'spelling': ['abbreviated_tokens', 'pinyin_syllables', 'aligned_separators', 'normalized_input_units', 'bits_per_normalized_unit', 'word_boundary_separators'],
}
V2_FEATURES = V1_FEATURES + [name for group in V2_GROUPS.values() for name in group]
FEATURE_GROUPS = {
    'frequency': ['word_log_count_mean', 'word_log_count_min', 'unigram_logp_sum', 'unigram_logp_mean', 'unigram_logp_min'],
    'internal_grams': ['internal_ngram_logp_sum', 'internal_ngram_logp_mean', 'internal_ngram_logp_min', 'internal_ngram_hit_ratio', 'internal_ngram_max_order', 'internal_ngram_log_support_mean'],
    'context': ['context_available', 'at_sentence_start', 'context_history_words', 'candidate_context_logp', 'candidate_context_gain', 'context_ngram_hit_order'],
    'spelling': ['is_exact_spelling', 'abbreviated_syllable_ratio', 'completion_missing_letters', 'explicit_separator_alignment'],
    'structure': ['token_count', 'single_han_token_ratio', 'language_switch_count', 'candidate_language'],
    'user_lexicon': ['user_lexicon_available', 'user_word_hit_ratio', 'user_word_log_count_mean', 'user_word_log_count_min', 'user_unigram_logp_mean', 'user_unigram_lift_mean'],
    'user_grams': ['user_gram_available', 'user_internal_ngram_hit_ratio', 'user_internal_ngram_log_support_mean', 'user_internal_ngram_gain_mean', 'user_context_ngram_log_support', 'user_candidate_context_gain'],
}
FEATURE_GROUPS['correction'] = ['is_corrected', 'correction_edit_count', 'correction_cost_bits', 'correction_missing_key', 'correction_neighbor_key', 'correction_adjacent_swap']
FEATURES = [name for group in FEATURE_GROUPS.values() for name in group]
FEATURE_SETS = ['all', 'v1', 'without_user'] + ['without_' + name for name in FEATURE_GROUPS]
SCHEMAS = {'si-rank-features-v1': V1_FEATURES, 'si-rank-features-v2': V2_FEATURES, SCHEMA: FEATURES}


def select_features(rows, available, selection):
    groups = FEATURE_GROUPS if available == FEATURES else V2_GROUPS
    if selection == 'all':
        names = available
    elif selection == 'v1':
        names = V1_FEATURES
    elif selection == 'without_user':
        names = [name for name in available if not name.startswith('user_')]
    elif selection.startswith('add_'):
        names = V1_FEATURES + groups[selection[4:]]
    else:
        omitted = groups[selection[8:]]
        names = [name for name in available if name not in omitted]
    if not set(names) <= set(available):
        raise ValueError('Feature selection is incompatible with this prepared schema')
    indices = [available.index(name) for name in names]
    projected = [{**row, 'candidates': [{**candidate, 'features': [candidate['features'][i] for i in indices]}
                  for candidate in row['candidates']]} for row in rows]
    return projected, names


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def normalized(text):
    return unicodedata.normalize('NFC', text).lower().replace('u:', 'ü').replace('v', 'ü').replace("'", '')


def validate_sets(train, validation, test):
    seen_ids, families, queries, targets = set(), {}, {}, {}
    for split, rows in [('train', train), ('validation', validation), ('test', test)]:
        if not rows:
            raise ValueError(f'{split} is empty')
        local_queries = set()
        for row in rows:
            for key in ['id', 'family', 'input', 'category', 'origin']:
                if not isinstance(row.get(key), str) or not row[key]:
                    raise ValueError(f'{split}: missing {key}')
            if row['id'] in seen_ids:
                raise ValueError('Repeated query ID')
            seen_ids.add(row['id'])
            if split != 'test' and not isinstance(row.get('context'), str):
                raise ValueError('Context must be an explicit string')
            if 'context_available' in row and (not isinstance(row['context_available'], bool)
                    or (not row['context_available'] and row.get('context'))):
                raise ValueError('Context availability must be a boolean consistent with supplied text')
            if row.get('languages') not in [['zh-Hans', 'en'], ['zh-Hans'], ['en']]:
                raise ValueError('Invalid enabled languages')
            refs = row.get('references')
            if not isinstance(refs, list) or not refs or any(not isinstance(r, str) or not r for r in refs) or len(set(refs)) != len(refs):
                raise ValueError('References must be distinct nonempty strings')
            query = normalized(row['input'])
            context = row.get('context', '')
            local_key = (row['input'], json.dumps(context), tuple(row['languages']))
            if split != 'test' and local_key in local_queries:
                raise ValueError(f'{split}: duplicate query')
            local_queries.add(local_key)
            for registry, values in [(families, [row['family']]), (queries, [query]),
                                     (targets, [normalized(r) for r in refs])]:
                for value in values:
                    if value in registry and registry[value] != split:
                        raise ValueError(f'Cross-split overlap: {registry[value]} / {split}, row {row["id"]}')
                    registry[value] = split
    return {'train': len(train), 'validation': len(validation), 'test': len(test)}


def load_sources(args):
    paths = [args.train, args.validation, ROOT / 'eval/ranking/test.jsonl']
    rows = [read_rows(path) for path in paths]
    counts = validate_sets(*rows)
    return rows[:2], {name: {'sha256': sha(path), 'queries': counts[name]}
                     for name, path in zip(['train', 'validation', 'test'], paths)}


def export_rows(binary, lexicon, grams, rows, schema=SCHEMA, user_lexicon=None, user_grams=None, correction=False):
    command = [str(binary.resolve()), 'rank-features', str(lexicon.resolve())]
    if grams:
        command += ['--grams', str(grams.resolve())]
    if correction:
        command += ['--pinyin-correction']
    if schema == 'si-rank-features-v2':
        command += ['--legacy-v2']
    if user_lexicon:
        command += ['--user-lexicon', str(user_lexicon.resolve())]
    if user_grams:
        command += ['--user-grams', str(user_grams.resolve())]
    names = SCHEMAS[schema]
    requests = ''.join(f'{r["input"].encode().hex()}\t{r["context"].encode().hex()}\t{",".join(r["languages"])}\t{int(r.get("context_available", bool(r["context"])))}\n' for r in rows)
    result = subprocess.run(command, input=requests, text=True, capture_output=True, timeout=600)
    if result.returncode:
        raise ValueError('Rust feature exporter failed (no input text logged)')
    lines = iter(result.stdout.splitlines())
    if next(lines, '') != schema + '\t' + ','.join(names):
        raise ValueError('Rust/Python feature schema mismatch')
    exported = []
    for row in rows:
        pool, identities = [], set()
        for line in lines:
            if line.startswith('END\t'):
                total = int(line.split('\t')[1])
                if len(pool) != min(total, 64):
                    raise ValueError('Incomplete candidate pool')
                break
            language, text, feature_text = line.split('\t')
            text = bytes.fromhex(text).decode('utf-8')
            values = [None if v == 'null' and schema == SCHEMA else float(v) for v in feature_text.split(',')]
            key = (language, text)
            allowed = row['languages'] + (['mixed'] if len(row['languages']) == 2 else [])
            if language not in allowed or not text or key in identities or len(values) != len(names) or not all(v is None or math.isfinite(v) for v in values):
                raise ValueError('Invalid exported candidate')
            identities.add(key)
            pool.append({'text': text, 'language': language, 'features': values,
                         'label': int(text in row['references'])})
        else:
            raise ValueError('Missing candidate group terminator')
        exported.append({**row, 'total_eligible': total, 'candidates': pool})
    if next(lines, None) is not None:
        raise ValueError('Unexpected extra exporter output')
    return exported


def prepare(args):
    (train, validation), sources = load_sources(args)
    if args.output.exists():
        raise ValueError('Output directory already exists; choose a new snapshot')
    user_lexicon = getattr(args, 'user_lexicon', None)
    user_grams = getattr(args, 'user_grams', None)
    snapshot_note = getattr(args, 'user_snapshot_note', None)
    schema = getattr(args, 'schema', SCHEMA)
    if user_grams and not user_lexicon:
        raise ValueError('User grams require their paired user lexicon')
    if user_lexicon and (schema != SCHEMA or not snapshot_note or not snapshot_note.strip()):
        raise ValueError('User resources require v3 and --user-snapshot-note documenting a snapshot predating every query')
    def resource_hashes():
        return {'exporter': sha(args.binary), 'lexicon': sha(args.lexicon),
                'grams': sha(args.grams) if args.grams else None,
                'user_lexicon': sha(user_lexicon) if user_lexicon else None,
                'user_grams': sha(user_grams) if user_grams else None}
    binaries = resource_hashes()
    exported = [export_rows(args.binary, args.lexicon, args.grams, rows, schema, user_lexicon, user_grams, getattr(args, 'pinyin_correction', False))
                for rows in [train, validation]]
    if binaries != resource_hashes():
        raise ValueError('Resources changed during export')
    if sources != load_sources(args)[1]:
        raise ValueError('Source datasets changed during export')
    args.output.mkdir(parents=True)
    files = {}
    for name, rows in zip(['train', 'validation'], exported):
        path = args.output / f'{name}.jsonl'
        path.write_text(''.join(json.dumps(r, ensure_ascii=False, allow_nan=False) + '\n' for r in rows))
        files[path.name] = sha(path)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    diff = subprocess.check_output(['git', 'diff', 'HEAD', '--', 'crates'], cwd=ROOT)
    # Include untracked implementation files as well as the working-tree diff.
    source_hashes = {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / 'crates').rglob('*.rs'))}
    write_json(args.output / 'manifest.json', {'schema': schema, 'features': SCHEMAS[schema],
               'protocol': 'first-64-complete-noncompletion-dictionary-paths-v1',
               'pinyin_correction': getattr(args, 'pinyin_correction', False),
               'sources': sources, 'resources': binaries, 'files': files, 'git_revision': revision,
               'rust_diff_sha256': hashlib.sha256(diff).hexdigest(), 'rust_sources': source_hashes,
               'pipeline_sha256': sha(__file__), 'labels': 'binary intended-reference / weak-negative',
               'personal_state': {'user_snapshot_note': snapshot_note, 'user_resources_supplied': bool(user_lexicon)}, 'limits': 'Synthetic starter data; no production quality claim.'})
    print(json.dumps({'prepared': str(args.output), 'baseline': [metrics(r)['overall'] for r in exported]}, ensure_ascii=False))


def load_bundle(path):
    manifest = json.loads((path / 'manifest.json').read_text())
    if manifest['features'] != SCHEMAS.get(manifest['schema']):
        raise ValueError('Incompatible feature schema')
    for name in ['train.jsonl', 'validation.jsonl']:
        if sha(path / name) != manifest['files'][name]:
            raise ValueError('Prepared bundle checksum mismatch')
    return [read_rows(path / name) for name in ['train.jsonl', 'validation.jsonl']], manifest


def metrics(rows, model=None):
    results = []
    for row in rows:
        pool = row['candidates']
        if model is not None and pool:
            scores = model.predict([c['features'] for c in pool], num_threads=1)
            if not all(math.isfinite(float(v)) for v in scores):
                raise ValueError('Nonfinite model prediction')
            # Stable baseline order resolves ties; identity and candidate bytes stay unchanged.
            pool = [pool[i] for i in sorted(range(len(pool)), key=lambda i: (-float(scores[i]), i))]
        rank = next((i + 1 for i, c in enumerate(pool) if c['label'] > 0), None)
        dcg = sum(c['label'] / math.log2(i + 2) for i, c in enumerate(pool[:5]))
        ideal = sum(1 / math.log2(i + 2) for i in range(min(5, sum(c['label'] for c in pool))))
        results.append({'id': row['id'], 'category': row['category'], 'rank': rank,
                        'ndcg5': dcg / ideal if ideal else 0.0})
    def summarize(group):
        n = len(group)
        return {'queries': n, 'pool_recall': sum(r['rank'] is not None for r in group) / n,
                'top1': sum(r['rank'] == 1 for r in group) / n,
                'top5': sum(r['rank'] is not None and r['rank'] <= 5 for r in group) / n,
                'mrr': sum(1 / r['rank'] if r['rank'] else 0 for r in group) / n,
                'ndcg5': sum(r['ndcg5'] for r in group) / n}
    categories = defaultdict(list)
    for r in results:
        categories[r['category']].append(r)
    return {'overall': summarize(results), 'by_category': {k: summarize(v) for k, v in sorted(categories.items())},
            'results': results}


def training_matrix(rows):
    x, y, groups = [], [], []
    for row in rows:
        pool = row['candidates']
        if len({c['label'] for c in pool}) != 2:
            continue
        groups.append(len(pool))
        x.extend(c['features'] for c in pool)
        y.extend(c['label'] for c in pool)
    if not groups:
        raise ValueError('No informative query groups: need both a retrieved positive and a negative')
    return x, y, groups


def train(args):
    import lightgbm as lgb
    import numpy as np
    import scipy
    (train_rows, valid_rows), manifest = load_bundle(args.bundle)
    if args.output.exists():
        raise ValueError('Run directory already exists; choose a new run')
    train_rows, names = select_features(train_rows, manifest['features'], args.feature_set)
    valid_rows, _ = select_features(valid_rows, manifest['features'], args.feature_set)
    x, y, group = training_matrix(train_rows)
    vx, vy, vgroup = training_matrix(valid_rows)
    categorical = ['candidate_language'] if 'candidate_language' in names else []
    dataset = lgb.Dataset(np.asarray(x, dtype=float), label=y, group=group, feature_name=names, categorical_feature=categorical)
    validation = lgb.Dataset(np.asarray(vx, dtype=float), label=vy, group=vgroup, reference=dataset)
    params = dict(objective='lambdarank', metric='ndcg', ndcg_eval_at=[1, 5], label_gain=[0, 1],
                  lambdarank_truncation_level=6, learning_rate=0.05, num_leaves=7,
                  min_data_in_leaf=5, max_depth=3, lambda_l2=1.0,
                  seed=17, num_threads=1, deterministic=True, force_col_wise=True, verbosity=-1)
    model = lgb.train(params, dataset, num_boost_round=args.rounds, valid_sets=[validation],
                      callbacks=[lgb.early_stopping(30, first_metric_only=True, verbose=False)])
    args.output.mkdir(parents=True)
    model.save_model(str(args.output / 'model.txt'))
    saved = lgb.Booster(model_file=str(args.output / 'model.txt'))
    if not np.allclose(model.predict(np.asarray(vx, dtype=float)), saved.predict(np.asarray(vx, dtype=float)), rtol=0, atol=1e-12):
        raise ValueError('Saved model prediction mismatch')
    report = {'baseline': metrics(valid_rows), 'lambdarank': metrics(valid_rows, saved),
              'training_groups': len(group), 'validation_early_stopping_groups': len(vgroup),
              'excluded_training_groups': len(train_rows) - len(group),
              'excluded_validation_early_stopping_groups': len(valid_rows) - len(vgroup),
              'best_iteration': model.best_iteration,
              'feature_set': args.feature_set,
              'feature_observations': {name: {
                  'train_nonmissing': sum(c['features'][i] is not None for r in train_rows for c in r['candidates']),
                  'train_distinct': len({c['features'][i] for r in train_rows for c in r['candidates'] if c['features'][i] is not None}),
              } for i, name in enumerate(names)},
              'importance': {name: {'splits': int(count), 'gain': float(gain)} for name, count, gain in zip(names, saved.feature_importance(), saved.feature_importance(importance_type='gain'))},
              'scope': 'Validation used for early stopping; not held-out test quality. Missing gold remains in report denominators.'}
    write_json(args.output / 'report.json', report)
    write_json(args.output / 'run.json', {'schema': manifest['schema'], 'features': names, 'feature_set': args.feature_set, 'params': params,
               'rounds': args.rounds, 'best_iteration': model.best_iteration,
               'bundle_manifest_sha256': sha(args.bundle / 'manifest.json'),
               'model_sha256': sha(args.output / 'model.txt'), 'lightgbm': lgb.__version__,
               'numpy': np.__version__, 'scipy': scipy.__version__, 'python': sys.version, 'pipeline_sha256': sha(__file__),
               'requirements_sha256': sha(Path(__file__).with_name('requirements.txt')),
               'training_sources': manifest['sources']})
    print(json.dumps({k: report[k]['overall'] for k in ['baseline', 'lambdarank']}))


def evaluate(args):
    import lightgbm as lgb
    (_, rows), manifest = load_bundle(args.bundle)
    run = json.loads((args.run / 'run.json').read_text())
    rows, names = select_features(rows, manifest['features'], run.get('feature_set', 'all'))
    if run['schema'] != manifest['schema'] or run['features'] != names or sha(args.run / 'model.txt') != run['model_sha256']:
        raise ValueError('Model checksum/schema mismatch')
    if sha(args.bundle / 'manifest.json') != run['bundle_manifest_sha256']:
        raise ValueError('Run was trained against a different bundle')
    report = {'baseline': metrics(rows), 'lambdarank': metrics(rows, lgb.Booster(model_file=str(args.run / 'model.txt')))}
    if args.output.exists():
        raise ValueError('Report already exists')
    write_json(args.output, report)
    print(json.dumps({k: v['overall'] for k, v in report.items()}))


def ablate(args):
    if args.output.exists():
        raise ValueError('Comparison directory already exists')
    (_, _), manifest = load_bundle(args.bundle)
    if manifest['schema'] != SCHEMA:
        raise ValueError('Ablations require a v3 bundle')
    bundle_hash = sha(args.bundle / 'manifest.json')
    args.output.mkdir(parents=True)
    results = {}
    for feature_set in [s for s in FEATURE_SETS if s != 'v1']:
        destination = args.output / feature_set
        train(argparse.Namespace(bundle=args.bundle, output=destination,
                                 rounds=args.rounds, feature_set=feature_set))
        if sha(args.bundle / 'manifest.json') != bundle_hash:
            raise ValueError('Prepared bundle changed during ablation')
        report = json.loads((destination / 'report.json').read_text())
        results[feature_set] = {key: report[key] for key in ['baseline', 'lambdarank', 'best_iteration', 'importance']}
    write_json(args.output / 'comparison.json', {
        'bundle_manifest_sha256': sha(args.bundle / 'manifest.json'),
        'feature_groups': FEATURE_GROUPS,
        'scope': 'Same frozen candidates and labels for every feature set; development validation uses early stopping.',
        'experiments': results,
    })


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ['validate', 'prepare']:
        p = sub.add_parser(name)
        p.add_argument('--train', type=Path, default=DATA / 'train.jsonl')
        p.add_argument('--validation', type=Path, default=DATA / 'validation.jsonl')
        if name == 'prepare':
            p.add_argument('--binary', type=Path, default=ROOT / 'target/release/si-cli')
            p.add_argument('--lexicon', type=Path, required=True)
            p.add_argument('--grams', type=Path)
            p.add_argument('--schema', choices=[SCHEMA, 'si-rank-features-v2'], default=SCHEMA)
            p.add_argument('--user-lexicon', type=Path)
            p.add_argument('--user-grams', type=Path)
            p.add_argument('--user-snapshot-note')
            p.add_argument('--pinyin-correction', action='store_true')
            p.add_argument('--output', type=Path, required=True)
    for name in ['train', 'evaluate', 'ablate']:
        p = sub.add_parser(name)
        p.add_argument('--bundle', type=Path, required=True)
        p.add_argument('--output', type=Path, required=True)
        if name in ['train', 'ablate']:
            p.add_argument('--rounds', type=int, default=300)
            if name == 'train':
                p.add_argument('--feature-set', choices=FEATURE_SETS, default='all')
        else:
            p.add_argument('--run', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'validate':
            print(json.dumps(load_sources(args)[1], indent=2))
        elif args.command == 'prepare':
            prepare(args)
        elif args.command in ['train', 'ablate']:
            if args.rounds <= 0:
                raise ValueError('Rounds must be positive')
            if args.command == 'ablate':
                ablate(args)
            else:
                train(args)
        else:
            evaluate(args)
    except (ValueError, OSError, KeyError, ImportError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{type(error).__name__}: {error}\n')


if __name__ == '__main__':
    main()
