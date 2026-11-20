#!/usr/bin/env python3
"""Compare V5 score reconstruction with edge probabilities from an isolated Rust build."""
import argparse
from collections import Counter
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.lambdarank import pipeline

LEXICAL = 'lexical_score_bits'
PURE = 'pure_probability_bits'
LANGUAGES = ('zh-Hans', 'en', 'mixed')
LIMIT = 1e-6


def pure_probability(features, indices):
    def value(name):
        return features[indices[name]]

    score = value(LEXICAL)
    if score is None:
        return None
    missing = value('completion_missing_letters')
    return (
        score + 1 + 4 * value('language_switch_count') + value('english_token_count')
        + (2 / math.log(2)) * value('single_han_token_count')
        + (4 + missing if missing > 0 else 0)
        + 7 * value('abbreviated_token_count') + value('correction_cost_bits')
    )


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise ValueError(f'Audit instrumentation anchor changed in {path}')
    path.write_text(source.replace(old, new))


def instrumented_cli(workspace):
    for name in ('Cargo.toml', 'Cargo.lock'):
        shutil.copy2(ROOT / name, workspace / name)
    shutil.copytree(ROOT / 'crates', workspace / 'crates')
    shutil.copytree(ROOT / 'config', workspace / 'config')
    engine = workspace / 'crates/si-engine/src'
    evidence = engine / 'ranking_features.rs'
    replace_once(evidence, '    pub unigram_bits: f64,',
                 '    pub edge_log2_probabilities: Vec<f64>,\n    pub unigram_bits: f64,')
    replace_once(evidence, '            statistics: Vec::new(),',
                 '            statistics: Vec::new(),\n'
                 '            edge_log2_probabilities: self.edge_log2_probabilities.iter()\n'
                 '                .chain(&next.edge_log2_probabilities).copied().collect(),')
    replace_once(engine / 'conversion/scoring.rs', '                unigram_bits: base_prior.log2(),',
                 '                edge_log2_probabilities: vec![priors.personalized.log2()],\n'
                 '                unigram_bits: base_prior.log2(),')
    cli = workspace / 'crates/si-cli/src/rank_features.rs'
    replace_once(cli, '                    writeln!(output, "{language}\\t{text}\\t{features}")?;',
                 '                    let edge_bits = candidate.ranking_evidence.as_ref().unwrap()\n'
                 '                        .edge_log2_probabilities.iter().map(f64::to_string)\n'
                 '                        .collect::<Vec<_>>().join(",");\n'
                 '                    writeln!(output, "{language}\\t{text}\\t{features}\\t{edge_bits}")?;')
    target = workspace / 'target'
    subprocess.run(['cargo', 'build', '--release', '--locked', '--offline', '-p', 'si-cli',
                    '--manifest-path', str(workspace / 'Cargo.toml'), '--target-dir', str(target)],
                   env={**os.environ, 'TMPDIR': str(workspace)}, check=True, cwd=workspace)
    return target / 'release/si-cli'


def collect(binary, rows):
    names = pipeline.V5_LEXICAL_FEATURES
    indices = {name: index for index, name in enumerate(names)}
    command = [
        str(binary), 'rank-features', str(pipeline.DEFAULT_RESOURCES / 'main.silex'),
        '--grams', str(pipeline.DEFAULT_RESOURCES / 'words.sigram'), '--v5', '--model-correction-pool',
    ]
    requests = ''.join(
        '\t'.join((row['input'].encode().hex(), row['context'].encode().hex(),
                   ','.join(row['languages']), str(int(bool(row['context']))),
                   pipeline.encode_preferences(row))) + '\n'
        for row in rows
    )
    result = subprocess.run(command, input=requests, text=True, stdout=subprocess.PIPE, check=True)
    lines = iter(result.stdout.splitlines())
    if next(lines) != pipeline.V5_LEXICAL_SCHEMA + '\t' + ','.join(names):
        raise ValueError('Unexpected audit feature schema')
    candidates = []
    for row in rows:
        for line in lines:
            if line.startswith('END\t'):
                break
            language, text, features, edge_bits = line.split('\t')
            values = [None if value == 'null' else float(value) for value in features.split(',')]
            edges = [float(value) for value in edge_bits.split(',')]
            if len(edges) != values[indices['token_count']]:
                raise ValueError('Expected one independent probability per lexical edge')
            if len(edges) < 2:
                continue
            direct = math.fsum(edges)
            reconstructed = pure_probability(values, indices)
            candidates.append({
                'id': row['id'], 'input': row['input'], 'language': language,
                'candidate': bytes.fromhex(text).decode(), 'edge_log2_probabilities': edges,
                'direct_bits': direct, 'reconstructed_bits': reconstructed,
                'absolute_error_bits': abs(direct - reconstructed),
                'is_corrected': bool(values[indices['is_corrected']]),
                'is_completion': bool(values[indices['is_completion']]),
                'is_abbreviated': bool(values[indices['abbreviated_token_count']]),
            })
        else:
            raise ValueError('Missing audit query terminator')
    if next(lines, None) is not None:
        raise ValueError('Unexpected extra audit candidates')
    return candidates


def sample(candidates):
    result = []
    for language in LANGUAGES:
        matching = [row for row in candidates if row['language'] == language]
        # Cover costly paths before taking ordinary paths, round-robin across queries.
        matching.sort(key=lambda row: (not row['is_corrected'], not row['is_abbreviated'],
                                       not row['is_completion']))
        seen, first, remaining = set(), [], []
        for row in matching:
            (first if row['id'] not in seen else remaining).append(row)
            seen.add(row['id'])
        result.extend((first + remaining)[:100])
    if Counter(row['language'] for row in result) != dict.fromkeys(LANGUAGES, 100):
        raise ValueError('Expected 100 multiword candidates per language')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    rows = pipeline.read_queries(pipeline.DATA / 'train.jsonl') + pipeline.read_queries(pipeline.DATA / 'validation.jsonl')
    with tempfile.TemporaryDirectory(prefix='si-v5-edge-audit-', dir='/tmp') as temporary:
        samples = sample(collect(instrumented_cli(Path(temporary)), rows))
    errors = [row['absolute_error_bits'] for row in samples]
    report = {
        'samples': len(samples), 'languages': Counter(row['language'] for row in samples),
        'query_count': len({row['id'] for row in samples}), 'user_resources': False,
        'completion_samples': sum(row['is_completion'] for row in samples),
        'abbreviation_samples': sum(row['is_abbreviated'] for row in samples),
        'correction_samples': sum(row['is_corrected'] for row in samples),
        'max_error_bits': max(errors), 'mean_error_bits': statistics.fmean(errors),
        'limit_bits': LIMIT, 'passed': max(errors) <= LIMIT,
    }
    with (args.output / 'samples.jsonl').open('x') as stream:
        for row in samples:
            stream.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
    pipeline.write_json(args.output / 'report.json', report)
    print(json.dumps(report))
    if not report['passed']:
        sys.exit('Probability verification failed. Stop before training.')


if __name__ == '__main__':
    main()
