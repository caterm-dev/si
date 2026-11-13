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
from common import REPO, digest, new_directory, write_json


def build(output):
    inputs = sorted((REPO / 'Data/Chinese').glob('*.csv'))
    # Reuse the dictionary compiler's overlap/weight contract rather than treating
    # duplicate categories as repeated natural-language occurrences.
    sys.path.insert(0, str(REPO / 'scripts'))
    import csv_dictionary
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
        notice_dir = REPO / 'mac/SI/Core/Resources/Chinese'
        notices = staged / 'attribution'
        notices.mkdir()
        sources = sorted(path for path in notice_dir.iterdir()
                         if path.is_file() and path.suffix in {'.txt', '.md'})
        for path in sources:
            shutil.copy2(path, notices / path.name)
        write_json(staged / 'manifest.json', {
            'schema_version': 1, 'language': 'zh', 'counts': dict(counts),
            'inputs': {str(path.relative_to(REPO)): digest(path) for path in inputs + sources},
            'files': {name: digest(staged / name) for name in ('characters.tsv', 'words.tsv')},
            'code': {name: digest(REPO / name) for name in
                     ('corpus/pinyin/build.py', 'corpus/common.py', 'corpus/clean/chinese.py',
                      'scripts/csv_dictionary.py')},
            'notes': 'Explicit lexical readings, preserving polyphony. Weights are not corpus counts. '
                     'No sentence pronunciation generation or train/validation/test assignment.',
        })
        print(json.dumps(dict(counts), sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output)
