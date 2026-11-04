#!/usr/bin/env python3
"""Verify reviewed homophone corrections against HanLP tokens and exact source spans."""

import argparse
from collections import Counter
import csv
import json
from pathlib import Path

if __package__:
    from .common import digest
    from .hanlp_words import source_inputs
else:
    from common import digest
    from hanlp_words import source_inputs


def count_spans(text, words):
    counts = Counter()
    for width in sorted({len(word) for word in words}):
        for start in range(len(text) - width + 1):
            word = text[start:start + width]
            if word in words:
                counts[word] += 1
    return counts


def check(corrections, segmented, bundles):
    with corrections.open(encoding='utf-8', newline='') as handle:
        rows = list(csv.DictReader(handle))
    if not rows or len({r['text'] for r in rows}) != len(rows):
        raise ValueError('Corrections must be nonempty and have unique outputs')
    inputs = source_inputs(bundles)
    configuration = json.loads((segmented / 'configuration.json').read_text())
    if configuration['sources'] != [s for _, s in inputs]:
        raise ValueError('Source versions/order differ from segmentation')
    report = json.loads((segmented / 'manifest.json').read_text())
    manifests = {s['id']: s for s in report['sources']}
    words = {r[key] for r in rows for key in ('text', 'reference_text')}
    surfaces, tokens = {}, {}
    for directory, source in inputs:
        name = source['source']['id']
        surfaces[name], tokens[name] = Counter(), Counter()
        with (directory / 'text.txt').open(encoding='utf-8') as text_file:
            for line in text_file:
                # Every fragment remains a boundary; overlapping occurrences count.
                surfaces[name].update(count_spans(line.rstrip('\n'), words))
        path = segmented / name / 'counts.csv'
        if digest(path) != manifests[name]['counts_sha256']:
            raise ValueError('Token-count checksum mismatch')
        with path.open(encoding='utf-8') as handle:
            for token in csv.DictReader(handle):
                if token['text'] in words:
                    tokens[name][token['text']] = int(token['count'])
    for row in rows:
        text, reference = row['text'], row['reference_text']
        total = sum(c[text] for c in tokens.values())
        reference_total = sum(c[reference] for c in surfaces.values())
        if total != int(row['hanlp_count']) or reference_total != int(row['reference_surface_count']):
            raise ValueError('Correction totals differ: ' + text)
        wins = []
        for name in tokens:
            if (int(row[name]) != tokens[name][text]
                    or int(row['reference_' + name]) != surfaces[name][reference]):
                raise ValueError('Per-source evidence differs: ' + text)
            if tokens[name][text] >= 10 and tokens[name][text] >= 2 * max(1, surfaces[name][reference]):
                wins.append(name)
        old, new, reference_weight = map(int, (row['old_weight'], row['new_weight'], row['reference_weight']))
        if (total < 100 or total < 4 * max(1, reference_total)
                or len(wins) < 3 or not {'lccc', 'mc4'}.issubset(wins)
                or not old < new <= 2 * old or new != (reference_weight * 105 + 99) // 100):
            raise ValueError('Correction is outside the reviewed evidence/weight bounds: ' + text)
        print(f'Verified {text}: {total} tokens vs {reference_total} reference spans; {old} -> {new}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--corrections', type=Path, required=True)
    parser.add_argument('--segmented', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, action='append', required=True)
    args = parser.parse_args()
    check(args.corrections, args.segmented, args.bundle)
