#!/usr/bin/env python3
"""Segment Chinese base.csv and phrase/**/*.csv with offline HanLP; sum word weights."""

import argparse
from collections import defaultdict
import csv
import itertools
import os
from pathlib import Path
import re
import sys
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from corpus.hanlp_words import CACHE, MODEL, configure_cache, fetch, load_tokenizer, tokenize_chunk

COLUMNS = ['text', 'reading', 'weight']
MAX_WEIGHT = 2**63 - 1
FINE_MODEL = 'https://file.hankcs.com/hanlp/tok/fine_electra_small_20220615_231803.zip'
FINE_CACHE = ROOT / 'corpus/.cache/hanlp-fine'
# Explicit source spellings with non-character-aligned readings in the legacy
# movie collection. Apply only when ordinary character alignment is impossible.
ALIASES = {'II': ('er',), '33': ('san', 'shi', 'san'),
           'F': ('ai', 'fu'), 'X': ('ai', 'ke', 'si')}


def is_separator(character):
    return unicodedata.category(character).startswith(('P', 'Z'))


def reading_boundaries(text, reading):
    """Map exact source character boundaries to original syllable offsets."""
    syllables = reading.split("'")
    if not all(re.fullmatch('[a-z]+', syllable) for syllable in syllables):
        raise ValueError('Expected an explicit lowercase apostrophe-separated reading')
    ordinary = sum(not is_separator(character) for character in text)
    use_aliases = ordinary != len(syllables)
    boundaries = {0: 0}
    position = offset = 0
    while position < len(text):
        alias = next((key for key in ALIASES if use_aliases and text.startswith(key, position)), None)
        if alias:
            expected = ALIASES[alias]
            if tuple(syllables[offset:offset + len(expected)]) != expected:
                raise ValueError('Source alias does not match its original reading')
            position += len(alias)
            offset += len(expected)
        else:
            offset += not is_separator(text[position])
            position += 1
        boundaries[position] = offset
    if offset != len(syllables):
        raise ValueError('Cannot align text with its original reading')
    return syllables, boundaries


def word_readings(text, reading, tokens):
    if (not isinstance(tokens, (list, tuple)) or not tokens
            or any(not isinstance(token, str) or not token for token in tokens)
            or ''.join(tokens) != text):
        raise ValueError('Tokenizer changed the input or returned invalid boundaries')
    syllables, boundaries = reading_boundaries(text, reading)
    start = 0
    result = []
    for token in tokens:
        end = start + len(token)
        if start not in boundaries or end not in boundaries:
            raise ValueError('Tokenizer split inside a non-character-aligned source alias')
        token_reading = "'".join(syllables[boundaries[start]:boundaries[end]])
        # Standalone punctuation/space has no Pinyin and is not a vocabulary word.
        if token_reading:
            result.append((token, token_reading))
        start = end
    return result


def source_rows(source):
    base = source / 'base.csv'
    if not base.is_file():
        raise ValueError(f'{base}: missing required base.csv')
    paths = [base, *sorted((source / 'phrase').rglob('*.csv'))]
    for path in paths:
        if path.is_symlink():
            raise ValueError(f'{path}: symbolic-link CSV inputs are unsupported')
        with path.open(encoding='utf-8-sig', newline='') as handle:
            reader = csv.reader(handle, strict=True)
            if next(reader, None) != COLUMNS:
                raise ValueError(f'{path}: expected text,reading,weight header')
            for row in reader:
                location = f'{path}:{reader.line_num}'
                try:
                    if len(row) != 3:
                        raise ValueError('Expected three CSV fields')
                    text, reading, raw_weight = row
                    if not text.strip() or any(ord(c) < 32 or ord(c) == 127 for c in text):
                        raise ValueError('Invalid vocabulary text')
                    # Match the legacy default for blank local-category weights.
                    weight = 10 if raw_weight == '' else int(raw_weight)
                    if (raw_weight and not re.fullmatch('[0-9]+', raw_weight)) or not 0 <= weight <= MAX_WEIGHT:
                        raise ValueError('Expected a nonnegative signed-64-bit weight')
                    reading_boundaries(text, reading)
                except ValueError as error:
                    raise ValueError(f'{location}: {error}') from error
                yield text, reading, weight, location


def convert(source, output, tokenizer, batch_size=256, chunk_rows=8192):
    source, output = source.resolve(), output.resolve()
    if output == source or source in output.parents:
        raise ValueError('Output must be outside the input tree')
    totals = defaultdict(int)
    processed = 0
    rows = iter(source_rows(source))
    while chunk := list(itertools.islice(rows, chunk_rows)):
        predictions = tokenize_chunk(tokenizer, [row[0] for row in chunk], batch_size)
        for (text, reading, weight, location), tokens in zip(chunk, predictions, strict=True):
            try:
                for identity in word_readings(text, reading, tokens):
                    totals[identity] += weight
                    if totals[identity] > MAX_WEIGHT:
                        raise ValueError('Summed weight exceeds the signed-64-bit CSV limit')
            except ValueError as error:
                raise ValueError(f'{location}: {error}') from error
        processed += len(chunk)
        print(f'Processed {processed:,} source rows; {len(totals):,} word/readings', flush=True)
    if not totals:
        raise ValueError('Segmentation produced no vocabulary words')
    # Publish only a complete result; failed conversion leaves any prior CSV intact.
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=output.parent, prefix='.migration-', suffix='.csv')
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='') as handle:
            writer = csv.writer(handle, lineterminator='\n')
            writer.writerow(COLUMNS)
            for text, reading in sorted(totals, key=lambda pair: (pair[1].encode(), pair[0].encode())):
                writer.writerow((text, reading, totals[(text, reading)]))
        os.replace(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)
    print(f'Wrote {output}: {len(totals):,} word/readings from {processed:,} rows', flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'Data/Vocabulary/chinese',
                        help='Chinese directory; read only base.csv and CSVs recursively under phrase/')
    parser.add_argument('--output', type=Path, default=ROOT / 'Data/Chinese/base.csv')
    parser.add_argument('--device', choices=('cpu', 'mps'), default='cpu')
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--batch-size', type=int, default=256)
    parser.add_argument('--chunk-rows', type=int, default=8192)
    parser.add_argument('--granularity', choices=('fine', 'coarse'), default='coarse',
                        help='HanLP segmentation granularity (default: coarse)')
    parser.add_argument('--fetch-model', action='store_true',
                        help='Explicitly download and lock the selected model, then exit without converting')
    args = parser.parse_args(argv)
    if min(args.threads, args.batch_size, args.chunk_rows) < 1:
        parser.error('Thread, batch and chunk sizes must be positive')
    try:
        model, cache = (FINE_MODEL, FINE_CACHE) if args.granularity == 'fine' else (MODEL, CACHE)
        configure_cache(cache)
        print(f'HanLP {args.granularity}: {model}', flush=True)
        if args.fetch_model:
            fetch(model=model, cache=cache)
            return
        tokenizer, _ = load_tokenizer(args.device, args.threads, model=model, cache=cache)
        convert(args.source, args.output, tokenizer, args.batch_size, args.chunk_rows)
    except (ValueError, OSError, csv.Error, ImportError) as error:
        parser.exit(1, f'Chinese vocabulary migration error: {error}\n')


if __name__ == '__main__':
    main()
