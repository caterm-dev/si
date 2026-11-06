#!/usr/bin/env python3
"""Build a unigram reference from flat Chinese word CSVs, excluding subdirectories."""
import argparse
import csv
import json
from pathlib import Path

if __package__:
    from .common import ROOT, CHINESE, digest, new_directory, write_json
    from .tokenize_unigram import HAN, normalize_line
else:
    from common import ROOT, CHINESE, digest, new_directory, write_json
    from tokenize_unigram import HAN, normalize_line


def build(words_directory, frequencies, output):
    # Deliberately nonrecursive: phrase/ is an input-method maintenance group,
    # not a source for this segmentation vocabulary. Shared words may still be
    # supplied independently by a word-side CSV.
    sources = sorted(words_directory.glob('*.csv'))
    if not sources:
        raise ValueError('No word-side CSV sources')
    identities = {str(path): digest(path) for path in sources}
    frequency_sha = digest(frequencies)
    if output.exists():
        record = json.loads((output / 'manifest.json').read_text())
        if (record['sources'] != identities or record['frequency_reference_sha256'] != frequency_sha
                or digest(output / 'frequencies.csv') != record['sha256']):
            raise ValueError('Existing dictionary has different inputs or altered output; choose a new destination')
        return record
    words = set()
    for path in sources:
        if path.is_symlink():
            raise ValueError('Word sources must be regular files')
        with path.open(encoding='utf-8', newline='') as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames != ['text', 'reading', 'weight']:
                raise ValueError('Unexpected word CSV header')
            for row in reader:
                word = normalize_line(row['text']).strip()
                if HAN.fullmatch(word):
                    words.add(word)
    counts = {}
    with frequencies.open(encoding='utf-8', newline='') as handle:
        for row in csv.DictReader(handle):
            word = normalize_line(row['text']).strip()
            if word in words:
                count = int(row['count'])
                if count < 0:
                    raise ValueError('Negative corpus frequency')
                counts[word] = counts.get(word, 0) + count
    if not words:
        raise ValueError('No Han words after normalization')
    observed = sum(counts.get(word, 0) > 0 for word in words)
    with new_directory(output) as stage:
        with (stage / 'frequencies.csv').open('w', encoding='utf-8', newline='') as handle:
            writer = csv.writer(handle, lineterminator='\n')
            writer.writerow(['text', 'count'])
            writer.writerows((word, max(1, counts.get(word, 0))) for word in sorted(words))
        if identities != {str(path): digest(path) for path in sources} or digest(frequencies) != frequency_sha:
            raise ValueError('Dictionary inputs changed during construction')
        record = {'contract': 'flat-chinese-word-csv-unigram-v1',
                  'sources': identities, 'excluded_subdirectory': str(words_directory / 'phrase'),
                  'policy': 'Only flat CSV text columns supply words. Subdirectories are not read. '
                            'Readings and input-method ranking weights do not supply counts. '
                            'Corpus counts are summed after normalization; unobserved words receive pseudocount 1. '
                            'A word independently present in a flat word CSV is retained even if a phrase source repeats it.',
                  'frequency_reference': str(frequencies), 'frequency_reference_sha256': frequency_sha,
                  'words': len(words), 'observed_words': observed, 'smoothed_words': len(words)-observed,
                  'maximum_word_length': max(map(len, words)),
                  'sha256': digest(stage / 'frequencies.csv')}
        write_json(stage / 'manifest.json', record)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--words-directory', type=Path, default=ROOT.parent / 'Data/Vocabulary/chinese')
    parser.add_argument('--frequencies', type=Path, default=CHINESE / 'dictionaries/generated/unigram-reference-v1/frequencies.csv')
    parser.add_argument('--output', type=Path, default=CHINESE / 'dictionaries/generated/unigram-words-v2')
    args = parser.parse_args()
    record = build(args.words_directory, args.frequencies, args.output)
    print(json.dumps(record, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
