#!/usr/bin/env python3
"""Export explicit character/word readings from SI's maintained Chinese vocabulary."""

import argparse
from collections import Counter
import csv
import json
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from clean.chinese import HAN
from common import REPO, ROOT, digest, new_directory, write_json


def build(output):
    vocabulary = REPO / 'Data/Vocabulary'
    inputs = sorted((vocabulary / 'chinese').glob('*.csv'))
    # Reuse the dictionary compiler's overlap/weight contract rather than treating
    # duplicate categories as repeated natural-language occurrences.
    sys.path.insert(0, str(REPO / 'scripts'))
    import csv_dictionary
    metadata, _ = csv_dictionary.metadata()
    entries, _ = csv_dictionary.rows('chinese')
    with new_directory(output) as staged:
        counts = Counter()
        with (staged / 'characters.tsv').open('w', encoding='utf-8', newline='') as characters, \
                (staged / 'words.tsv').open('w', encoding='utf-8', newline='') as words:
            writers = {True: csv.writer(characters, delimiter='\t', lineterminator='\n'),
                       False: csv.writer(words, delimiter='\t', lineterminator='\n')}
            for writer in writers.values():
                writer.writerow(['text', 'reading', 'weight'])
            for text, reading, weight in entries:
                if not HAN.fullmatch(text) or len(reading.split("'")) != len(text):
                    counts['excluded_non_han_or_unaligned'] += 1
                    continue
                single = len(text) == 1
                writers[single].writerow([text, reading, weight])
                counts['characters' if single else 'words'] += 1
        notices = staged / 'attribution'
        notices.mkdir()
        for source in metadata['upstreams']:
            path = REPO / source['attribution']
            target = notices / source['attribution']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        shutil.copytree(vocabulary / 'Wanxiang', notices / 'Wanxiang',
                        ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy2(vocabulary / 'meta.json', staged / 'vocabulary-meta.json')
        write_json(staged / 'manifest.json', {
            'schema_version': 1, 'language': 'zh', 'counts': dict(counts),
            'inputs': {str(path.relative_to(REPO)): digest(path) for path in inputs + [vocabulary / 'meta.json']},
            'files': {name: digest(staged / name) for name in ('characters.tsv', 'words.tsv')},
            'code': {name: digest(REPO / name) for name in
                     ('corpus/pinyin/build.py', 'corpus/common.py', 'corpus/clean/chinese.py',
                      'scripts/csv_dictionary.py', 'scripts/lexicon_database.py')},
            'notes': 'Explicit lexical readings, preserving polyphony. Weights are not corpus counts. '
                     'No sentence pronunciation generation or train/validation/test assignment.',
        })
        print(json.dumps(dict(counts), sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output)
