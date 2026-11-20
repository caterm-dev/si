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
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'eval/lambdarank'
DEFAULT_RESOURCES = ROOT / 'target/si-data'
EXPORT_BATCH_SIZE = 512
SCHEMA = 'si-rank-features-v3'
NEURAL_SCHEMA = 'si-rank-features-v4'
V5_LEXICAL_SCHEMA = 'si-rank-features-v5-lexical'
V5_SCHEMA = 'si-rank-features-v5'

# The command is also loaded directly by the pipeline tests.
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts.lambdarank import neural_features
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
NEURAL_GROUPS = {**FEATURE_GROUPS, **neural_features.FEATURE_GROUPS}
NEURAL_FEATURES = FEATURES + [name for group in neural_features.FEATURE_GROUPS.values() for name in group]
V5_ADDITIONS = {
    'path_counts': ['abbreviated_token_count', 'abbreviated_syllable_count', 'pinyin_syllable_count',
                    'english_token_count', 'single_han_token_count', 'is_completion', 'has_exact_dictionary_match'],
    'baseline_evidence': ['base_gram_available', 'lexical_score_bits', 'field_context_adjustment_bits'],
    'choice_history': ['user_choice_whole_bonus', 'user_choice_token_bonus'],
}
V5_LEXICAL_GROUPS = {**FEATURE_GROUPS, **V5_ADDITIONS}
V5_NEURAL_GROUPS = {**V5_LEXICAL_GROUPS, **neural_features.FEATURE_GROUPS}
V5_LEXICAL_FEATURES = [name for names in V5_LEXICAL_GROUPS.values() for name in names]
V5_FEATURES = [name for names in V5_NEURAL_GROUPS.values() for name in names]
MERGED_SCHEMAS = {NEURAL_SCHEMA: SCHEMA, V5_SCHEMA: V5_LEXICAL_SCHEMA}
GROUPS_BY_SCHEMA = {SCHEMA: FEATURE_GROUPS, NEURAL_SCHEMA: NEURAL_GROUPS,
                    V5_LEXICAL_SCHEMA: V5_LEXICAL_GROUPS, V5_SCHEMA: V5_NEURAL_GROUPS}
FEATURE_SETS = ['all', 'v1', 'without_user', 'without_neural', 'without_v5_additions'] + [
    'without_' + name for name in V5_NEURAL_GROUPS]
SCHEMAS = {'si-rank-features-v1': V1_FEATURES, 'si-rank-features-v2': V2_FEATURES, SCHEMA: FEATURES,
           NEURAL_SCHEMA: NEURAL_FEATURES, V5_LEXICAL_SCHEMA: V5_LEXICAL_FEATURES, V5_SCHEMA: V5_FEATURES}


def select_features(rows, available, selection):
    schema = next((schema for schema, names in SCHEMAS.items() if names == available), None)
    groups = GROUPS_BY_SCHEMA.get(schema, V2_GROUPS)
    if selection == 'all':
        names = available
    elif selection == 'v1':
        names = V1_FEATURES
    elif selection == 'without_neural':
        names = V5_LEXICAL_FEATURES if schema == V5_SCHEMA else FEATURES
    elif selection == 'without_v5_additions':
        names = NEURAL_FEATURES if schema == V5_SCHEMA else FEATURES
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


def read_queries(path):
    rows = read_rows(path)
    for row in rows:
        row.setdefault('context', '')
        row.setdefault('languages', ['zh-Hans', 'en'])
        row.setdefault('category', 'general')
        if 'id' not in row:
            request = [row.get(k) for k in ('input', 'context', 'languages')]
            digest = hashlib.sha256(json.dumps(request, ensure_ascii=False).encode()).hexdigest()
            row['id'] = f'query-{digest[:24]}'
    return rows


def encode_preferences(row):
    """Serialize explicit pre-request observations without passing reference labels to Rust."""
    rows = row.get('prior_choices', [])
    if not isinstance(rows, list) or len(rows) > 128:
        raise ValueError('Invalid prior_choices list')
    encoded, seen = [], set()
    enabled = set(row['languages'])
    if len(enabled) == 2:
        enabled.add('mixed')
    for item in rows:
        if not isinstance(item, dict) or set(item) - {'text', 'language', 'bonus', 'token_spelling'}:
            raise ValueError('Invalid prior choice fields')
        text, language, bonus = (item.get(key) for key in ['text', 'language', 'bonus'])
        spelling = item.get('token_spelling', '')
        if (not isinstance(text, str) or not 0 < len(text.encode()) <= 512
                or not isinstance(language, str) or language not in enabled
                or type(bonus) not in (int, float) or not 0 <= bonus <= 32
                or not isinstance(spelling, str) or len(spelling.encode()) > 128
                or ('token_spelling' in item and (not spelling or language == 'mixed'))):
            raise ValueError('Invalid prior choice')
        if (language, spelling, text) in seen:
            raise ValueError('Duplicate prior choice')
        seen.add((language, spelling, text))
        encoded.append(f'{language}:{bonus}:{spelling.encode().hex()}:{text.encode().hex()}')
    return ','.join(encoded)


def validate_sets(train, validation, test):
    seen_ids, families, queries, targets = set(), {}, {}, {}
    for split, rows in [('train', train), ('validation', validation), ('test', test)]:
        if not rows:
            raise ValueError(f'{split} is empty')
        local_queries = set()
        for row in rows:
            for key in ['id', 'input', 'category']:
                if not isinstance(row.get(key), str) or not row[key]:
                    raise ValueError(f'{split}: missing {key}')
            for key in ('family', 'origin'):
                if key in row and (not isinstance(row[key], str) or not row[key]):
                    raise ValueError(f'{split}: invalid {key}')
            if row['id'] in seen_ids:
                raise ValueError('Repeated query ID')
            seen_ids.add(row['id'])
            if split != 'test' and not isinstance(row.get('context'), str):
                raise ValueError('Context must be an explicit string')
            if 'context_available' in row and (not isinstance(row['context_available'], bool)
                    or (not row['context_available'] and row.get('context'))):
                raise ValueError('Context availability must be a boolean consistent with supplied text')
            paths = row.get('syllable_paths', [])
            if not isinstance(paths, list) or len(paths) > 3 or any(not isinstance(p, str) or not p for p in paths):
                raise ValueError('syllable_paths must contain up to three observed Pinyin segmentations')
            if row.get('languages') not in [['zh-Hans', 'en'], ['zh-Hans'], ['en']]:
                raise ValueError('Invalid enabled languages')
            encode_preferences(row)
            refs = row.get('references')
            if not isinstance(refs, list) or not refs or any(not isinstance(r, str) or not r for r in refs) or len(set(refs)) != len(refs):
                raise ValueError('References must be distinct nonempty strings')
            query = normalized(row['input'])
            context = row.get('context', '')
            local_key = (row['input'], json.dumps(context), tuple(row['languages']))
            if split != 'test' and local_key in local_queries:
                raise ValueError(f'{split}: duplicate query')
            local_queries.add(local_key)
            for registry, values in [(families, [row['family']] if 'family' in row else []), (queries, [query]),
                                     (targets, [normalized(r) for r in refs])]:
                for value in values:
                    if value in registry and registry[value] != split:
                        raise ValueError(f'Cross-split overlap: {registry[value]} / {split}, row {row["id"]}')
                    registry[value] = split
    return {'train': len(train), 'validation': len(validation), 'test': len(test)}


def load_sources(args):
    paths = [getattr(args, 'train', DATA / 'train.jsonl'),
             getattr(args, 'validation', DATA / 'validation.jsonl'),
             ROOT / 'eval/ranking/test.jsonl']
    rows = [read_queries(path) for path in paths]
    counts = validate_sets(*rows)
    return rows[:2], {name: {'sha256': sha(path), 'queries': counts[name]}
                     for name, path in zip(['train', 'validation', 'test'], paths)}


def export_rows(binary, lexicon, grams, rows, schema=SCHEMA, user_lexicon=None, user_grams=None,
                correction=False, model_correction_pool=False, pinyin_paths=False):
    command = [str(binary.resolve()), 'rank-features', str(lexicon.resolve())]
    if grams:
        command += ['--grams', str(grams.resolve())]
    if correction:
        command += ['--pinyin-correction']
    if model_correction_pool:
        command += ['--model-correction-pool']
    if pinyin_paths:
        command += ['--pinyin-paths']
    if schema == 'si-rank-features-v2':
        command += ['--legacy-v2']
    elif schema == V5_LEXICAL_SCHEMA:
        command += ['--v5']
    if user_lexicon:
        command += ['--user-lexicon', str(user_lexicon.resolve())]
    if user_grams:
        command += ['--user-grams', str(user_grams.resolve())]
    names = SCHEMAS[schema]
    requests = []
    for row in rows:
        columns = [row['input'].encode().hex(), row['context'].encode().hex(), ','.join(row['languages']),
                   str(int(row.get('context_available', bool(row['context']))))]
        if schema == V5_LEXICAL_SCHEMA:
            columns.append(encode_preferences(row))
        requests.append('\t'.join(columns) + '\n')
    result = subprocess.run(command, input=''.join(requests), text=True, capture_output=True, timeout=600)
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
                fields = line.split('\t')
                if len(fields) != (3 if pinyin_paths else 2):
                    raise ValueError('Invalid candidate group terminator')
                total = int(fields[1])
                if len(pool) != min(total, 64):
                    raise ValueError('Incomplete candidate pool')
                break
            language, text, feature_text = line.split('\t')
            text = bytes.fromhex(text).decode('utf-8')
            values = [None if v == 'null' and schema in (SCHEMA, V5_LEXICAL_SCHEMA) else float(v) for v in feature_text.split(',')]
            key = (language, text)
            allowed = row['languages'] + (['mixed'] if len(row['languages']) == 2 else [])
            if language not in allowed or not text or key in identities or len(values) != len(names) or not all(v is None or math.isfinite(v) for v in values):
                raise ValueError('Invalid exported candidate')
            identities.add(key)
            pool.append({'text': text, 'language': language, 'features': values,
                         'label': int(text in row['references'])})
        else:
            raise ValueError('Missing candidate group terminator')
        result = {**row, 'total_eligible': total, 'candidates': pool}
        if pinyin_paths:
            result['model_syllable_paths'] = fields[2].split('|') if fields[2] else []
        exported.append(result)
    if next(lines, None) is not None:
        raise ValueError('Unexpected extra exporter output')
    return exported


def resolve_resources(args, schema):
    lexicon = getattr(args, 'lexicon', None)
    grams = getattr(args, 'grams', None)
    if lexicon is None:
        lexicon = DEFAULT_RESOURCES / 'main.silex'
        grams = grams or DEFAULT_RESOURCES / 'words.sigram'

    user_lexicon = getattr(args, 'user_lexicon', None)
    user_grams = getattr(args, 'user_grams', None)
    without_user = getattr(args, 'without_user', False)
    if user_grams and not user_lexicon:
        raise ValueError('User grams require their paired user lexicon')
    if user_lexicon and (without_user or schema == 'si-rank-features-v2'):
        raise ValueError('User resources require a user-enabled v3 or v5 exporter')
    if user_lexicon is None and not without_user and schema != 'si-rank-features-v2':
        default_lexicon = DEFAULT_RESOURCES / 'user.silex'
        default_grams = DEFAULT_RESOURCES / 'user.sigram'
        if any(path.exists() or path.is_symlink() for path in (default_lexicon, default_grams)):
            if not (default_lexicon.is_file() and default_grams.is_file()):
                raise ValueError('Stage both user.silex and user.sigram in target/si-data, or pass --without-user')
            user_lexicon, user_grams = default_lexicon, default_grams
    return lexicon, grams, user_lexicon, user_grams


def prepare(args):
    (train, validation), sources = load_sources(args)
    if args.output.exists():
        raise ValueError('Output directory already exists; choose a new snapshot')
    binary = getattr(args, 'binary', ROOT / 'target/release/si-cli')
    snapshot_note = getattr(args, 'user_snapshot_note', None)
    pinyin_model = getattr(args, 'pinyin_model', None)
    reranker_model = getattr(args, 'reranker_model', None)
    if bool(pinyin_model) != bool(reranker_model):
        raise ValueError('Pass both --pinyin-model and --reranker-model to prepare the merged pool')
    schema = getattr(args, 'schema', None) or (V5_SCHEMA if pinyin_model else V5_LEXICAL_SCHEMA)
    if bool(pinyin_model) != (schema in MERGED_SCHEMAS):
        raise ValueError('The merged model pool requires a neural schema and both checkpoints')
    rust_schema = MERGED_SCHEMAS.get(schema, schema)
    model_correction_pool = getattr(args, 'model_correction_pool', False)
    if model_correction_pool and rust_schema not in (SCHEMA, V5_LEXICAL_SCHEMA):
        raise ValueError('The model correction pool requires v3 or v5 correction features')
    lexicon, grams, user_lexicon, user_grams = resolve_resources(args, rust_schema)

    def resource_hashes():
        return {'exporter': sha(binary), 'lexicon': sha(lexicon),
                'grams': sha(grams) if grams else None,
                'user_lexicon': sha(user_lexicon) if user_lexicon else None,
                'user_grams': sha(user_grams) if user_grams else None,
                'pinyin_model': sha(pinyin_model) if pinyin_model else None,
                'reranker_model': sha(reranker_model) if reranker_model else None}
    binaries = resource_hashes()
    pinyin_correction = getattr(args, 'pinyin_correction', False)
    models = None
    model_metadata = None
    if pinyin_model:
        models = neural_features.NeuralModels(pinyin_model, reranker_model,
                                             getattr(args, 'device', 'cpu'), getattr(args, 'pinyin_beam', 8))
        python_files = [Path(neural_features.__file__)]
        for family in ['pinyin_to_text', 'reranker_small']:
            python_files.extend(sorted((ROOT / 'llm' / family).glob('*.py')))
        model_metadata = {**models.metadata, 'sources': {str(path.relative_to(ROOT)): sha(path) for path in python_files}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    baseline, files = [], {}
    with tempfile.TemporaryDirectory(prefix='.si-rank-features-', dir=args.output.parent) as temporary:
        stage = Path(temporary) / 'bundle'
        stage.mkdir()
        for name, rows in [('train', train), ('validation', validation)]:
            path = stage / f'{name}.jsonl'
            results = []
            with path.open('w', encoding='utf-8') as stream:
                for offset in range(0, len(rows), EXPORT_BATCH_SIZE):
                    batch = export_rows(binary, lexicon, grams, rows[offset:offset + EXPORT_BATCH_SIZE],
                                        rust_schema, user_lexicon, user_grams, pinyin_correction,
                                        model_correction_pool, pinyin_paths=bool(models and models.contextual))
                    if models is not None:
                        batch = [neural_features.merge_row(row, SCHEMAS[rust_schema], models.generate, models.score)
                                 for row in batch]
                    results.extend(metrics(batch)['results'])
                    for row in batch:
                        stream.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
            baseline.append(summarize_ranks(results))
            files[path.name] = sha(path)
        if binaries != resource_hashes():
            raise ValueError('Resources changed during export')
        if sources != load_sources(args)[1]:
            raise ValueError('Source datasets changed during export')
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        diff = subprocess.check_output(['git', 'diff', 'HEAD', '--', 'crates'], cwd=ROOT)
        source_hashes = {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / 'crates').rglob('*.rs'))}
        write_json(stage / 'manifest.json', {'schema': schema, 'features': SCHEMAS[schema],
                   'protocol': ('same-span-including-completions-v5' if rust_schema == V5_LEXICAL_SCHEMA else
                                'union-si-64-and-pinyin-beam-v1' if model_metadata else 'first-64-complete-noncompletion-dictionary-paths-v1'),
                   'neural_models': model_metadata, 'pinyin_correction': pinyin_correction,
                   'model_correction_pool': model_correction_pool,
                   'sources': sources, 'resources': binaries, 'files': files, 'git_revision': revision,
                   'rust_diff_sha256': hashlib.sha256(diff).hexdigest(), 'rust_sources': source_hashes,
                   'pipeline_sha256': sha(__file__), 'labels': 'binary intended-reference / weak-negative',
                   'personal_state': {'user_snapshot_note': snapshot_note, 'user_resources_supplied': bool(user_lexicon)},
                   'limits': 'Scenario labels; no production quality claim.'})
        if args.output.exists():
            raise ValueError('Output directory already exists; choose a new snapshot')
        stage.rename(args.output)
    return {'prepared': str(args.output), 'user_resources_supplied': bool(user_lexicon),
            'baseline': baseline}


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
    categories = defaultdict(list)
    for r in results:
        categories[r['category']].append(r)
    return {'overall': summarize_ranks(results),
            'by_category': {k: summarize_ranks(v) for k, v in sorted(categories.items())},
            'results': results}


def summarize_ranks(rows):
    n = len(rows)
    return {'queries': n, 'pool_recall': sum(r['rank'] is not None for r in rows) / n,
            'top1': sum(r['rank'] == 1 for r in rows) / n,
            'top5': sum(r['rank'] is not None and r['rank'] <= 5 for r in rows) / n,
            'mrr': sum(1 / r['rank'] if r['rank'] else 0 for r in rows) / n,
            'ndcg5': sum(r['ndcg5'] for r in rows) / n}


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


def neural_baselines(rows, manifest):
    if manifest['schema'] not in MERGED_SCHEMAS:
        return {}
    origin = manifest['features'].index('from_si_engine')
    logp = manifest['features'].index('reranker_logp_sum')
    penalty = manifest['neural_models']['reranker_baseline_length_penalty']

    def scorer_order(candidate):
        score = candidate['features'][logp]
        return math.inf if score is None else -score / len(candidate['text']) ** penalty

    si_rows = [{**row, 'candidates': [c for c in row['candidates'] if c['features'][origin]]} for row in rows]
    reranked = [{**row, 'candidates': sorted(row['candidates'], key=scorer_order)} for row in rows]
    return {'si_only': metrics(si_rows), 'reranker_small': metrics(reranked)}


def train(args):
    import lightgbm as lgb
    import numpy as np
    import scipy
    (train_rows, valid_rows), manifest = load_bundle(args.bundle)
    comparisons = neural_baselines(valid_rows, manifest)
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
    report = {'baseline': metrics(valid_rows), 'lambdarank': metrics(valid_rows, saved), **comparisons,
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
    print(json.dumps({k: report[k]['overall'] for k in ['baseline', 'lambdarank', *comparisons]}))


def prepare_and_train(args):
    if args.output.exists():
        raise ValueError('Run directory already exists; choose a new run')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.si-lambdarank-', dir=args.output.parent) as temporary:
        scratch = Path(temporary)
        bundle, staged_run = scratch / 'bundle', scratch / 'run'
        summary = prepare(argparse.Namespace(**(vars(args) | {'output': bundle})))
        train(argparse.Namespace(bundle=bundle, output=staged_run, rounds=args.rounds,
                                 feature_set=args.feature_set))
        bundle.rename(staged_run / 'bundle')
        if args.output.exists():
            raise ValueError('Run directory already exists; choose a new run')
        staged_run.rename(args.output)
    print(json.dumps({**summary, 'prepared': str(args.output / 'bundle')}, ensure_ascii=False))


def evaluate(args):
    import lightgbm as lgb
    (_, rows), manifest = load_bundle(args.bundle)
    comparisons = neural_baselines(rows, manifest)
    run = json.loads((args.run / 'run.json').read_text())
    rows, names = select_features(rows, manifest['features'], run.get('feature_set', 'all'))
    if run['schema'] != manifest['schema'] or run['features'] != names or sha(args.run / 'model.txt') != run['model_sha256']:
        raise ValueError('Model checksum/schema mismatch')
    if sha(args.bundle / 'manifest.json') != run['bundle_manifest_sha256']:
        raise ValueError('Run was trained against a different bundle')
    report = {'baseline': metrics(rows), 'lambdarank': metrics(rows, lgb.Booster(model_file=str(args.run / 'model.txt'))),
              **comparisons}
    if args.output.exists():
        raise ValueError('Report already exists')
    write_json(args.output, report)
    print(json.dumps({k: v['overall'] for k, v in report.items()}))


def ablate(args):
    if args.output.exists():
        raise ValueError('Comparison directory already exists')
    (_, _), manifest = load_bundle(args.bundle)
    groups = GROUPS_BY_SCHEMA.get(manifest['schema'])
    if groups is None:
        raise ValueError('Ablations require a v3 or newer bundle')
    selections = ['all', 'without_user', *('without_' + name for name in groups)]
    if manifest['schema'] in MERGED_SCHEMAS:
        selections.append('without_neural')
    if manifest['schema'] in (V5_SCHEMA, V5_LEXICAL_SCHEMA):
        selections.append('without_v5_additions')
    bundle_hash = sha(args.bundle / 'manifest.json')
    args.output.mkdir(parents=True)
    results = {}
    for feature_set in selections:
        destination = args.output / feature_set
        train(argparse.Namespace(bundle=args.bundle, output=destination,
                                 rounds=args.rounds, feature_set=feature_set))
        if sha(args.bundle / 'manifest.json') != bundle_hash:
            raise ValueError('Prepared bundle changed during ablation')
        report = json.loads((destination / 'report.json').read_text())
        results[feature_set] = {key: report[key] for key in ['baseline', 'lambdarank', 'best_iteration', 'importance']}
    write_json(args.output / 'comparison.json', {
        'bundle_manifest_sha256': sha(args.bundle / 'manifest.json'),
        'feature_groups': groups,
        'scope': 'Same frozen candidates and labels for every feature set; development validation uses early stopping.',
        'experiments': results,
    })


def add_source_arguments(parser):
    parser.add_argument('--train', type=Path)
    parser.add_argument('--validation', type=Path)


def add_preparation_arguments(parser):
    add_source_arguments(parser)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--lexicon', type=Path, help='Base lexicon (default: target/si-data/main.silex)')
    parser.add_argument('--grams', type=Path, help='Paired base grams (default with default lexicon: target/si-data/words.sigram)')
    parser.add_argument('--schema', choices=[V5_SCHEMA, V5_LEXICAL_SCHEMA, NEURAL_SCHEMA, SCHEMA, 'si-rank-features-v2'])
    parser.add_argument('--pinyin-model', type=Path)
    parser.add_argument('--reranker-model', type=Path)
    parser.add_argument('--pinyin-beam', type=int, choices=range(1, 33), metavar='1..32')
    parser.add_argument('--device', choices=['auto', 'cpu', 'mps', 'cuda'])
    user = parser.add_mutually_exclusive_group()
    user.add_argument('--user-lexicon', type=Path, help='Override the staged user lexicon')
    user.add_argument('--without-user', action='store_true', help='Skip the staged user snapshot')
    parser.add_argument('--user-grams', type=Path, help='Grams paired with the explicit --user-lexicon')
    parser.add_argument('--user-snapshot-note', help='Record the source and cutoff of the staged or explicit user snapshot')
    correction = parser.add_mutually_exclusive_group()
    correction.add_argument('--pinyin-correction', action='store_true')
    correction.add_argument('--model-correction-pool', action='store_true')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    validate_parser = sub.add_parser('validate', argument_default=argparse.SUPPRESS)
    add_source_arguments(validate_parser)
    prepare_parser = sub.add_parser('prepare', argument_default=argparse.SUPPRESS)
    add_preparation_arguments(prepare_parser)
    prepare_parser.add_argument('--output', type=Path, required=True)
    train_parser = sub.add_parser('train', argument_default=argparse.SUPPRESS)
    add_preparation_arguments(train_parser)
    train_parser.add_argument('--bundle', type=Path, default=None,
                              help='Use an existing bundle; omit to prepare from target/si-data and train')
    train_parser.add_argument('--output', type=Path, required=True)
    train_parser.add_argument('--rounds', type=int, default=300)
    train_parser.add_argument('--feature-set', choices=FEATURE_SETS, default='all')
    for name in ['evaluate', 'ablate']:
        p = sub.add_parser(name)
        p.add_argument('--bundle', type=Path, required=True)
        p.add_argument('--output', type=Path, required=True)
        if name == 'ablate':
            p.add_argument('--rounds', type=int, default=300)
        else:
            p.add_argument('--run', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'validate':
            print(json.dumps(load_sources(args)[1], indent=2))
        elif args.command == 'prepare':
            print(json.dumps(prepare(args), ensure_ascii=False))
        elif args.command in ['train', 'ablate']:
            if args.rounds <= 0:
                raise ValueError('Rounds must be positive')
            if args.command == 'ablate':
                ablate(args)
            elif args.bundle is None:
                prepare_and_train(args)
            else:
                if vars(args).keys() - {'command', 'bundle', 'output', 'rounds', 'feature_set'}:
                    raise ValueError('Preparation options require training without --bundle')
                train(args)
        else:
            evaluate(args)
    except (ValueError, OSError, KeyError, ImportError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{type(error).__name__}: {error}\n')


if __name__ == '__main__':
    main()
