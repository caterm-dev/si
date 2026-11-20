#!/usr/bin/env python3
"""Build contextual homophone and differently segmented ranking scenarios."""
import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
import json
import random
import shutil
import tempfile

from generate_training import ZH, vocabulary
from pipeline import DATA, ROOT, normalized, read_queries, sha, validate_sets, write_json

SEED = 20261124
DEFAULT_OUTPUT = DATA / 'generated/ambiguities-60k-v1'
DEFAULT_TRAIN = DATA / 'generated/training-100k-v2/train-combined.jsonl'
DEFAULT_VALIDATION = DATA / 'validation.jsonl'
FROZEN = ROOT / 'eval/ranking/test.jsonl'
LIMITS = {
    'contextual-homophone': 15000,
    'whole-homophone': 15000,
    'word-boundary': 18000,
    'syllable-boundary': 12000,
}
MIN_WEIGHT = 20


@dataclass(frozen=True)
class Word:
    text: str
    reading: tuple[str, ...]
    weight: int

    def spelling(self):
        return ''.join(self.reading)

    def record(self):
        return {'text': self.text, 'syllables': ' '.join(self.reading)}


def substitutions(index, part):
    return [word for word in index.get(part.reading, ()) if word.text != part.text]


def pieces(word, weights):
    for cut in range(1, len(word.text)):
        left, right = (word.text[:cut], word.reading[:cut]), (word.text[cut:], word.reading[cut:])
        left_weight, right_weight = weights.get(left, 0), weights.get(right, 0)
        if min(left_weight, right_weight) >= MIN_WEIGHT:
            yield Word(*left, left_weight), Word(*right, right_weight)


def alternatives(weights, ranked):
    homophones, syllable_paths = defaultdict(list), defaultdict(list)
    for text, reading in ranked:
        weight = weights[text, reading]
        if weight < MIN_WEIGHT:
            break
        if len(reading) > 5:
            continue
        word = Word(text, reading, weight)
        if len(homophones[reading]) < 4:
            homophones[reading].append(word)
        paths = syllable_paths[word.spelling()]
        if len(paths) < 4 and all(word.reading != peer.reading for peer in paths):
            paths.append(word)
    return homophones, syllable_paths


def choose_data(weights, ranked, existing, protected):
    held_inputs = {normalized(row['input']) for row in protected}
    held_refs = {normalized(ref) for row in protected for ref in row['references']}
    seen = {(normalized(row['input']), row['context'], tuple(row['languages'])) for row in existing}
    homophones, syllable_paths = alternatives(weights, ranked)
    items, counts, spelling_use, target_use = [], Counter(), Counter(), Counter()

    def add(kind, positive, negative, attested, context=''):
        category = 'homophone' if kind.endswith('homophone') else 'segmentation'
        source = ''.join(word.spelling() for word in positive)
        target = ''.join(word.text for word in positive)
        competitor = ''.join(word.text for word in negative)
        key = normalized(source), context, ('zh-Hans', 'en')
        if (counts[kind] >= LIMITS[kind] or key in seen or key[0] in held_inputs
                or spelling_use[key[0]] >= 4 or target_use[(category, target)] >= 3
                or target == competitor or normalized(target) in held_refs or normalized(competitor) in held_refs
                or normalized(attested.text) in held_refs or normalized(attested.spelling()) in held_inputs):
            return False
        seen.add(key)
        counts[kind] += 1
        spelling_use[key[0]] += 1
        target_use[(category, target)] += 1
        row = {'input': source, 'references': [target], 'category': category}
        if context:
            row['context'] = context
        evidence = {'mechanism': kind, 'input': source, 'context': context, 'reference': target,
                    'attestation': attested.record(), 'positive_path': [word.record() for word in positive],
                    'competing_path': [word.record() for word in negative]}
        items.append((row, evidence))
        return True

    for text, reading in ranked:
        if counts == LIMITS:
            break
        weight = weights[text, reading]
        if weight < MIN_WEIGHT:
            break
        if not 3 <= len(reading) <= 9:
            continue
        word = Word(text, reading, weight)
        split_paths = sorted(pieces(word, weights), key=lambda pair: -min(part.weight for part in pair))
        for left, right in split_paths:
            if 2 <= len(right.reading) <= 4:
                for alternative in substitutions(homophones, right):
                    if add('contextual-homophone', (right,), (alternative,), word, left.text):
                        break
            if counts['contextual-homophone'] >= LIMITS['contextual-homophone']:
                break
        for path in split_paths:
            for index, part in enumerate(path):
                if len(part.reading) < 2:
                    continue
                for alternative in substitutions(homophones, part):
                    competing = path[:index] + (alternative,) + path[index + 1:]
                    if add('whole-homophone', path, competing, word):
                        break
                if counts['whole-homophone'] >= LIMITS['whole-homophone']:
                    break
            if counts['whole-homophone'] >= LIMITS['whole-homophone']:
                break

        if counts['word-boundary'] < LIMITS['word-boundary'] and split_paths:
            positive = split_paths[0]
            gold_cut = len(positive[0].reading)
            for cut in range(1, len(reading)):
                if cut == gold_cut:
                    continue
                for left in homophones.get(reading[:cut], ()):
                    for right in homophones.get(reading[cut:], ()):
                        if add('word-boundary', positive, (left, right), word):
                            break
                    else:
                        continue
                    break
                else:
                    continue
                break

        if counts['syllable-boundary'] < LIMITS['syllable-boundary']:
            for path in [(word,), *split_paths]:
                for index, part in enumerate(path):
                    for alternative in syllable_paths.get(part.spelling(), ()):
                        if alternative.reading == part.reading:
                            continue
                        competing = path[:index] + (alternative,) + path[index + 1:]
                        if add('syllable-boundary', path, competing, word):
                            break
    if counts != LIMITS:
        raise ValueError(f'Could not satisfy evidence-backed quotas: {dict(counts)}')
    random.Random(SEED).shuffle(items)
    return items


def verify_evidence(items, weights):
    for row, evidence in items:
        paths = evidence['positive_path'], evidence['competing_path']
        syllables = []
        surfaces = []
        for path in paths:
            words = [(entry['text'], tuple(entry['syllables'].split())) for entry in path]
            if any(weights.get(word, 0) < MIN_WEIGHT for word in words):
                raise ValueError('Candidate path has an unsupported token')
            syllables.append(tuple(s for _, reading in words for s in reading))
            surfaces.append(''.join(text for text, _ in words))
        if (any(''.join(reading) != row['input'] for reading in syllables)
                or surfaces[0] != row['references'][0] or surfaces[0] == surfaces[1]):
            raise ValueError('Candidate paths do not explain the labeled query')
        attested = evidence['attestation']
        if (attested['text'] != row.get('context', '') + surfaces[0]
                or weights.get((attested['text'], tuple(attested['syllables'].split())), 0) < MIN_WEIGHT):
            raise ValueError('Expected output lacks the claimed lexical attestation')
        method = evidence['mechanism']
        if (method == 'syllable-boundary') == (syllables[0] == syllables[1]):
            raise ValueError('Syllable boundary evidence disagrees with method')
        if method == 'word-boundary':
            if len(paths[0]) != 2 or len(paths[1]) != 2 or len(paths[0][0]['text']) == len(paths[1][0]['text']):
                raise ValueError('Candidate paths do not have competing word boundaries')


def write_rows(path, rows):
    with path.open('w', encoding='utf-8') as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n')


def build(args):
    output = args.output
    if output.exists():
        raise ValueError('Use a new output directory')
    paths = [ZH, Path(__file__), args.base_train, DATA / 'train.jsonl', args.validation, FROZEN, *args.exclude]
    fingerprints = {path.resolve(): sha(path) for path in paths}
    validation, frozen = read_queries(args.validation), read_queries(FROZEN)
    reserved = [row for path in args.exclude for row in read_queries(path)]
    base = read_queries(args.base_train)
    existing = base + read_queries(DATA / 'train.jsonl')
    weights, ranked, _ = vocabulary()
    items = choose_data(weights, ranked, existing, validation + frozen + reserved)
    verify_evidence(items, weights)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.ambiguities-', dir=output.parent) as temporary:
        stage = Path(temporary) / 'data'
        stage.mkdir(mode=0o700)
        files = {}
        for category in ('homophone', 'segmentation'):
            path = stage / f'{category}.jsonl'
            write_rows(path, (row for row, _ in items if row['category'] == category))
            files[path.name] = {'rows': 30000, 'sha256': sha(path)}
        train_path = stage / 'train.jsonl'
        write_rows(train_path, (row for row, _ in items))
        evidence = stage / 'evidence.jsonl'
        write_rows(evidence, (item for _, item in items))
        additions = read_queries(train_path)
        splits = validate_sets(additions, validation, frozen + reserved)
        validate_sets(base + additions, validation, frozen)
        if any(sha(path) != checksum for path, checksum in fingerprints.items()):
            raise ValueError('A source changed during generation')
        files[train_path.name] = {'rows': len(additions), 'sha256': sha(train_path)}
        files[evidence.name] = {'rows': len(additions), 'sha256': sha(evidence)}
        write_json(stage / 'manifest.json', {
            'seed': SEED, 'counts': dict(Counter(row['category'] for row in additions)),
            'mechanisms': dict(Counter(item['mechanism'] for _, item in items)),
            'distinct_inputs': len({normalized(row['input']) for row in additions}),
            'with_preceding_text': sum(bool(row['context']) for row in additions),
            'validated_splits': splits, 'files': files,
            'sources': {str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path): checksum
                        for path, checksum in fingerprints.items()},
            'scope': ('Lexically attested and programmatically checked synthetic intent and competing paths. '
                      'Evidence is for audit only. The paths do not seed engine candidates; no human gold labels.'),
            'attribution': 'Wanxiang vocabulary contributors (CC BY 4.0), see docs/CHINESE_VOCABULARY.md.',
        })
        if output.exists():
            raise ValueError('Use a new output directory')
        stage.rename(output)
    print(json.dumps({'output': str(output), 'rows': len(additions)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--base-train', type=Path, default=DEFAULT_TRAIN)
    parser.add_argument('--validation', type=Path, default=DEFAULT_VALIDATION)
    parser.add_argument('--exclude', type=Path, action='append', default=[])
    try:
        build(parser.parse_args())
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
