#!/usr/bin/env python3
"""Check isolated App-ranking features and Rust/LightGBM predictions on development inputs."""
import argparse
import json
import os
from pathlib import Path

import lightgbm as lgb
import numpy as np

from v5_stage2 import EXTENSION_SLICES, LEXICAL_INDEX, NAMES, RESOURCES, VARIANTS, enrich, inspect, invoke, names, parse_csv
from v5_probability_audit import ROOT, pipeline
from scripts.lambdarank.export_runtime import node

PROBES = ('ci', 'goon', 'cannot', 'youyige', 'go on', 'hel', 'HEL', 'Hel', 'hEL',
          'v2.0', 'sample_name', 'a/b', 'nihao', "xi'an", 'xian')


def native_bundle(output, model, manifest):
    output.mkdir(parents=True)
    source = ROOT / '.build/si-llm-pinyin'
    for asset in ('pinyin', 'reranker'):
        (output / asset).symlink_to((source / asset).resolve(), target_is_directory=True)
    trees = model.dump_model()['tree_info']
    pipeline.write_json(output / 'lambdarank.json', {
        'schema': 1, 'feature_names': model.feature_name(),
        'pinyin_checkpoint_sha256': manifest['resources']['pinyin_model'],
        'reranker_checkpoint_sha256': manifest['resources']['reranker_model'],
        'beam_size': manifest['neural_models']['beam_size'],
        'trees': [node(tree['tree_structure']) for tree in trees],
    })


def runtime(binary, model_path):
    command = [str(binary), 'runtime', str(RESOURCES / 'main.silex'), str(RESOURCES / 'words.sigram'),
               str(model_path)]
    lines = iter(invoke(command, '\n'.join(PROBES) + '\n').splitlines())
    groups = []
    for query in PROBES:
        group = []
        for line in lines:
            if line == 'END':
                break
            text, score, features = line.split('\t')
            group.append((text, float(score), parse_csv(features)))
        else:
            raise ValueError(f'Missing App ranking result for {query}')
        groups.append(group)
    if next(lines, None) is not None:
        raise ValueError('Unexpected extra App ranking results')
    return groups


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--models', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    _, manifest = pipeline.load_bundle(args.bundle)
    queries = [{'input': text, 'context': '', 'languages': ['zh-Hans', 'en'], 'references': []}
               for text in PROBES]
    metadata = inspect(args.rust / 'si-cli', queries, {**manifest, 'model_correction_pool': False})
    buffers = dict(zip(PROBES, (fields for _, fields, _ in metadata), strict=True))
    if (buffers["xi'an"][:3] != [0.0, 1.0, 1.0] or buffers['xian'][2] <= buffers["xi'an"][2]
            or buffers['v2.0'][4:] != [1.0, 1.0, 0.0, 0.0]
            or buffers['sample_name'][4:] != [0.0, 0.0, 1.0, 0.0]
            or buffers['a/b'][4:] != [0.0, 0.0, 0.0, 1.0]
            or [buffers[key][3] for key in ('hel', 'HEL', 'Hel', 'hEL')] != [1.0, 2.0, 3.0, 4.0]):
        raise ValueError('Unexpected buffer facts on development probes')
    hel = metadata[PROBES.index('hel')][2]
    if hel['en', 'hello']['english_completion_ratio'] != 3 / 5:
        raise ValueError('Expected hel/hello to have completion ratio 3/5')
    binary = args.rust / 'v5-pool-features'
    args.output.mkdir(parents=True, exist_ok=False)
    report = {}
    language = {0: 'zh-Hans', 1: 'en', 2: 'mixed'}
    for variant in VARIANTS:
        model = lgb.Booster(model_file=str(args.models / f'{variant}.txt'))
        if model.feature_name() != names(variant):
            raise ValueError('Invalid experiment model features')
        path = args.output / variant
        native_bundle(path, model, manifest)
        groups = runtime(binary, path)
        feature_rows, rust_model_scores, enrichment_inputs = [], [], []
        shared_completion_paths = 0
        for group, (_, buffer, traces) in zip(groups, metadata, strict=True):
            lexical = [values[LEXICAL_INDEX] for _, _, values in group]
            ratios = []
            for text, score, values in group:
                feature_rows.append(values)
                rust_model_scores.append(score)
                edge = traces.get((language[values[24]], text))
                if variant in ('G', 'H') and edge:
                    if edge['english_completion_ratio'] != values[-1]:
                        raise ValueError(f'CLI and App disagree on completion metadata for {text}')
                    shared_completion_paths += edge['english_completion_ratio'] < 1.0
                ratio = values[-1] if variant in ('G', 'H') else 1.0
                ratios.append(ratio)
            enrichment_inputs.append((buffer, lexical, ratios))
        # Re-evaluate the very same native union, preserving all scored candidate identities.
        if variant != 'A':
            for group, extras in zip(groups, enrich(binary, enrichment_inputs), strict=True):
                for (_, _, values), expected in zip(group, extras, strict=True):
                    if values[len(NAMES):] != expected[EXTENSION_SLICES[variant]]:
                        raise ValueError('CLI and App extension features differ for the same pool')
        scores = model.predict(np.asarray(feature_rows, dtype=float), raw_score=True, num_threads=1)
        np.testing.assert_allclose(rust_model_scores, scores, atol=1e-12, rtol=0)
        report[variant] = {
            'scored_candidates': len(scores), 'nonempty_queries': sum(bool(group) for group in groups),
            'max_score_error': float(np.max(np.abs(np.asarray(rust_model_scores) - scores))),
            'shared_english_completion_paths_checked': shared_completion_paths,
        }
    for query, (_, buffer, _) in zip(PROBES, metadata, strict=True):
        print(f'{query!r}: {buffer}')
    pipeline.write_json(args.output / 'report.json', {'queries': PROBES, 'variants': report,
                                                     'buffer_features': buffers})
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
