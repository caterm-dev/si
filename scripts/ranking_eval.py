#!/usr/bin/env python3
"""Export blind ranking queries and score SICandidateExport JSONL responses."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path

from generate_ranking_eval import DESTINATION, COUNT, encoded, manifest, generate, validate


def digest(payload):
    return hashlib.sha256(payload).hexdigest()


def load():
    payload = (DESTINATION / 'test.jsonl').read_bytes()
    metadata = json.loads((DESTINATION / 'manifest.json').read_bytes())
    rows = [json.loads(line) for line in payload.splitlines()]
    validate(rows)
    if metadata != manifest(rows, payload) or payload != encoded(generate()):
        raise ValueError('Dataset or generator identity changed; validate the frozen suite')
    return rows, metadata['test_sha256']


def summarize(rows):
    count = len(rows)
    return {'queries': count, 'gold_in_exported_pool': sum(r['rank'] is not None for r in rows),
            'exported_pool_recall': sum(r['rank'] is not None for r in rows) / count,
            'top1': sum(r['rank'] == 1 for r in rows) / count,
            'top5': sum(r['rank'] is not None and r['rank'] <= 5 for r in rows) / count,
            'mrr': sum(1 / r['rank'] if r['rank'] else 0 for r in rows) / count}


def score(cases, predictions):
    expected = {row['id']: row for row in cases}
    seen = set()
    results = []
    for prediction in predictions:
        identity = prediction.get('id')
        if identity not in expected or identity in seen:
            raise ValueError('Unknown or repeated prediction ID')
        seen.add(identity)
        row = expected[identity]
        pool = prediction['candidates']
        if prediction['input'] != row['input'] or not isinstance(pool, list) or len(pool) > 32:
            raise ValueError('Mismatched input or invalid first-32 pool')
        if prediction['literalAvailable'] is not True:
            raise ValueError('Exact original input missing from engine results')
        if type(prediction['totalEligible']) is not int or prediction['totalEligible'] < 0 or len(pool) != min(32, prediction['totalEligible']):
            raise ValueError('Truncated or inconsistent exported pool')
        identities = set()
        for candidate in pool:
            if not isinstance(candidate.get('text'), str) or not candidate['text']:
                raise ValueError('Invalid candidate text')
            key = candidate.get('identity')
            if not isinstance(key, str) or not key or key in identities:
                raise ValueError('Missing or repeated language-aware candidate identity')
            identities.add(key)
            if candidate.get('language') not in row['languages']:
                raise ValueError('Unexpected candidate language')
        rank = next((i + 1 for i, c in enumerate(pool) if c['text'] in row['references']), None)
        results.append({'id': identity, 'category': row['category'], 'family': row['family'], 'rank': rank})
    if seen != set(expected):
        raise ValueError(f'Incomplete predictions: {len(seen)}/{len(expected)}')
    categories, families = defaultdict(list), defaultdict(list)
    for row in results:
        categories[row['category']].append(row)
        families[row['family']].append(row)
    family_scores = [summarize(group) for group in families.values()]
    return {'overall': summarize(results),
            'by_category': {name: summarize(group) for name, group in sorted(categories.items())},
            'family_macro_top1': sum(group['top1'] for group in family_scores) / len(family_scores),
            'results': sorted(results, key=lambda r: r['id'])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    sub = commands.add_parser('requests')
    sub.add_argument('--output', required=True, type=Path)
    sub = commands.add_parser('score')
    sub.add_argument('--predictions', required=True, type=Path)
    sub.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    rows, identity = load()
    if args.command == 'requests':
        payload = ''.join(json.dumps({key: r[key] for key in ('id', 'input', 'context')}, ensure_ascii=False) + '\n' for r in rows)
    else:
        source = args.predictions.read_bytes()
        report = score(rows, [json.loads(line) for line in source.splitlines()])
        report.update(dataset_sha256=identity, predictions_sha256=digest(source),
                      scorer_sha256=digest(Path(__file__).read_bytes()),
                      protocol='SICandidateExport dictionary-only bilingual first-32 full nonliteral/noncompletion candidates')
        payload = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    with args.output.open('x', encoding='utf-8') as stream:
        stream.write(payload)
    print(json.dumps({'output': str(args.output), 'queries': COUNT}))


if __name__ == '__main__':
    main()
