#!/usr/bin/env python3
"""Compare local HanLP counts with the maintained vocabulary; never edit dictionaries."""

import argparse
from collections import Counter, defaultdict
import csv
import json
import math
from pathlib import Path
import statistics

if __package__:
    from .clean.chinese import HAN
    from .common import REPO, digest, new_directory, write_json
else:
    from clean.chinese import HAN
    from common import REPO, digest, new_directory, write_json


def eligibility(text, count, line_count, supported_sources):
    if not HAN.fullmatch(text) or not 2 <= len(text) <= 7:
        return 'outside_length_or_script'
    if len(set(text)) == 1:
        return 'repeated_character'
    if count < 20 or line_count < 10:
        return 'low_frequency'
    if supported_sources < 2 and line_count < 100:
        return 'insufficient_source_support'
    return 'review'


def review(segmented, output):
    manifest = json.loads((segmented / 'manifest.json').read_text())
    names = [s['id'] for s in manifest['sources']]
    counts, lines = {}, {}
    totals, fragments = Counter(), Counter()
    for source in manifest['sources']:
        name = source['id']
        path = segmented / name / 'counts.csv'
        if digest(path) != source['counts_sha256']:
            raise ValueError('Word-count checksum mismatch: ' + name)
        counts[name], lines[name] = Counter(), Counter()
        with path.open(encoding='utf-8') as handle:
            for row in csv.DictReader(handle):
                word = row['text']
                counts[name][word] = int(row['count'])
                lines[name][word] = int(row['line_count'])
        totals.update(counts[name])
        fragments.update(lines[name])
    existing = defaultdict(dict)
    vocabulary = REPO / 'Data/Vocabulary'
    metadata = json.loads((vocabulary / 'meta.json').read_text())
    upstream = set(metadata['upstream_categories']['chinese'])
    # Same precedence as csv_dictionary.rows: local < imported < base.
    paths = sorted((vocabulary / 'chinese').glob('*.csv'),
                   key=lambda p: (2 if p.name == 'base.csv' else 1 if p.name in upstream else 0, p.name))
    for path in paths:
        tier = 2 if path.name == 'base.csv' else 1 if path.name in upstream else 0
        with path.open(encoding='utf-8-sig', newline='') as handle:
            for row in csv.DictReader(handle):
                if row['text'] not in totals:
                    continue
                word, reading = row['text'], row['reading']
                weight = int(row['weight'] or 10)
                old = existing[word].get(reading)
                if old is None or (tier, weight) > (old[0], old[1]):
                    existing[word][reading] = (tier, weight, path.name)
    # An editorial prior for NEW words only, anchored to observed existing words
    # of the same length/count bin. Raw corpus counts are never Wanxiang weights.
    anchors = defaultdict(list)
    for word, readings in existing.items():
        if 2 <= len(word) <= 7 and len(readings) == 1 and totals[word] >= 20:
            weight = next(iter(readings.values()))[1]
            if weight > 0:
                anchors[(len(word), int(math.log2(totals[word])))].append(weight)
    with new_directory(output) as stage:
        with (stage / 'frequencies.csv').open('w', encoding='utf-8', newline='') as all_file, \
                (stage / 'missing.csv').open('w', encoding='utf-8', newline='') as missing_file, \
                (stage / 'existing.csv').open('w', encoding='utf-8', newline='') as existing_file:
            all_writer, missing_writer, existing_writer = map(csv.writer, (all_file, missing_file, existing_file))
            header = ['text', 'count', 'line_count', 'supported_sources', *names]
            all_writer.writerow(header + ['status'])
            missing_writer.writerow(header + ['suggested_weight', 'anchor_words', 'status'])
            existing_writer.writerow(header + ['readings', 'weights', 'categories'])
            decisions = Counter()
            for word, count in sorted(totals.items(), key=lambda pair: (-pair[1], pair[0])):
                support = sum(lines[name][word] >= 3 for name in names)
                status = eligibility(word, count, fragments[word], support)
                fields = [word, count, fragments[word], support, *(counts[name][word] for name in names)]
                all_writer.writerow(fields + ['existing' if word in existing else status])
                if word in existing:
                    if status == 'review':
                        readings = sorted(existing[word])
                        existing_writer.writerow(fields + [
                            '|'.join(readings), '|'.join(str(existing[word][r][1]) for r in readings),
                            '|'.join(existing[word][r][2] for r in readings)])
                else:
                    decisions[status] += 1
                    if status == 'review':
                        pool = anchors.get((len(word), int(math.log2(count))), [])
                        weight = max(10, min(5000, round(statistics.median(pool)))) if pool else 10
                        missing_writer.writerow(fields + [weight, len(pool), 'pending_manual_review'])
        write_json(stage / 'manifest.json', {
            'schema_version': 1, 'segmentation_manifest_sha256': digest(segmented / 'manifest.json'),
            'vocabulary_inputs': {str(p.relative_to(REPO)): digest(p) for p in paths},
            'script_sha256': digest(Path(__file__)), 'total_types': len(totals),
            'missing_decisions': dict(decisions),
            'new_weight_policy': 'Median existing unambiguous-reading word weight of identical character '
                                 'length and floor(log2(count)) bin, clamped to 10..5000. '
                                 'Editorial suggestions only; raw counts do not replace upstream weights.',
            'files': {p.name: digest(p) for p in sorted(stage.glob('*.csv'))},
        })
    print(json.dumps(dict(decisions), sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--segmented', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    review(args.segmented, args.output)
