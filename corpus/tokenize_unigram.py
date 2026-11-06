#!/usr/bin/env python3
"""Normalize, split and tokenize UTF-8 text with a local unigram dictionary."""

import argparse
from collections import deque
from concurrent.futures import ProcessPoolExecutor, TimeoutError
from contextlib import ExitStack
import csv
from dataclasses import dataclass
import io
import itertools
import json
import math
import multiprocessing
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import unicodedata

HAN = re.compile(r'[\u4e00-\u9fff]+')
FRAGMENTS = re.compile(
    r'(?P<han>[\u4e00-\u9fff]+)'
    r"|(?P<english>[A-Za-z]+(?:['\-][A-Za-z]+)*)"
    r'|(?P<number>\d+(?:\.\d+)?)'
    r'|(?P<symbol>[^\s])'
)
SENTENCE_PUNCTUATION = frozenset('。！？!?.,，;；:：、…')
CLOSING_PUNCTUATION = frozenset('"\'”’」』）》〉】〕〗〙〛)]}')
MAX_WORDS = 100

# Nonprinting fillers/variation selectors not all classified as control/format.
# Whitespace is handled separately, preserving word boundaries until tokenization.
INVISIBLE_RANGES = (
    (0x034F, 0x034F), (0x115F, 0x1160), (0x17B4, 0x17B5),
    (0x180B, 0x180F), (0x2060, 0x206F), (0x2800, 0x2800),
    (0x3164, 0x3164), (0xFE00, 0xFE0F), (0xFFA0, 0xFFA0),
    (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A),
    (0xE0000, 0xE0FFF),
)


def normalize_line(text):
    text = unicodedata.normalize('NFKC', text)
    result = []
    for character in text:
        if character.isspace():
            result.append(' ')
        elif unicodedata.category(character) not in ('Cc', 'Cf', 'Cs'):
            value = ord(character)
            if not any(start <= value <= end for start, end in INVISIBLE_RANGES):
                result.append(character)
    return ''.join(result)


def sentences(text, punctuation=SENTENCE_PUNCTUATION):
    """Keep punctuation clusters/adjacent closing quotes with the preceding text."""
    start = 0
    pending_end = None
    # Decimal points and in-word apostrophes/hyphens are protected by the exact
    # fragment grammar, before deciding whether a symbol ends a sentence.
    for match in FRAGMENTS.finditer(text):
        symbol = match.group() if match.lastgroup == 'symbol' else None
        if pending_end is not None:
            if symbol is not None and (symbol in punctuation or
                                       (symbol in CLOSING_PUNCTUATION and match.start() == pending_end)):
                pending_end = match.end()
                continue
            sentence = text[start:pending_end].strip()
            if sentence:
                yield sentence
            start = pending_end
            pending_end = None
        if symbol in punctuation:
            pending_end = match.end()
    tail = text[start:].strip()
    if tail:
        yield tail


@dataclass
class UnigramDictionary:
    log_probabilities: dict[str, float]
    max_word_length: int
    unknown_log_probability: float
    lengths_by_initial: dict[str, tuple[int, ...]]

    @classmethod
    def from_counts(cls, counts):
        if not counts:
            raise ValueError('Dictionary contains no positive-frequency Han words')
        log_total = math.log(sum(counts.values()))
        scores = {word: math.log(count) - log_total for word, count in counts.items()}
        lengths = {}
        for word in scores:
            lengths.setdefault(word[0], set()).add(len(word))
        return cls(scores, max(map(len, scores)), min(scores.values()) - 5.0,
                   {initial: tuple(sorted(values)) for initial, values in lengths.items()})

    def segment(self, text):
        """Find the maximum sum of unigram log probabilities by suffix Viterbi."""
        size = len(text)
        best = [0.0] * (size + 1)
        following = [0] * size
        for start in range(size - 1, -1, -1):
            best_score = self.unknown_log_probability + best[start + 1]
            best_end = start + 1
            # Only lengths present for this initial can match. Their maximum is
            # bounded by the actual longest dictionary word, with no fixed cap.
            for length in self.lengths_by_initial.get(text[start], ()):
                end = start + length
                if end > size:
                    break
                log_probability = self.log_probabilities.get(text[start:end])
                if log_probability is None:
                    continue
                score = log_probability + best[end]
                if score > best_score or (score == best_score and end > best_end):
                    best_score, best_end = score, end
            best[start], following[start] = best_score, best_end
        tokens = []
        start = 0
        while start < size:
            end = following[start]
            tokens.append(text[start:end])
            start = end
        return tokens


def load_dictionary(path):
    """Read text/count CSV/TSV (extra columns allowed), or word/count plain text."""
    counts = {}
    with path.open(encoding='utf-8-sig', newline='') as handle:
        first = next((line for line in handle if line.strip() and not line.lstrip().startswith('#')), None)
        if first is None:
            return UnigramDictionary.from_counts(counts)
        delimiter = ',' if ',' in first else '\t' if '\t' in first else None
        lines = itertools.chain([first], handle)
        reader = csv.reader(lines, delimiter=delimiter, strict=True) if delimiter else (line.split() for line in lines)
        word_index, count_index = 0, 1
        has_header = False
        for index, row in enumerate(reader, 1):
            if not row or (delimiter is None and row[0].startswith('#')):
                continue
            if index == 1:
                header = [value.strip().lower() for value in row]
                word_columns = [i for i, name in enumerate(header) if name in ('text', 'word')]
                count_columns = [i for i, name in enumerate(header) if name in ('count', 'frequency', 'freq')]
                numeric_pair = len(row) == 2 and re.fullmatch(r'[0-9]+', row[1].strip())
                if word_columns and not numeric_pair:
                    if len(word_columns) != 1 or len(count_columns) != 1:
                        raise ValueError('Dictionary header needs one text/word and one count/frequency column; '
                                         'input-method ranking weights are not occurrence counts')
                    word_index, count_index = word_columns[0], count_columns[0]
                    has_header = True
                    continue
            if ((not has_header and len(row) != 2) or max(word_index, count_index) >= len(row)):
                raise ValueError(f'Dictionary record {index}: expected a word and frequency')
            word = normalize_line(row[word_index]).strip()
            if not HAN.fullmatch(word):
                continue
            raw_count = row[count_index].strip()
            if not re.fullmatch(r'[0-9]+', raw_count):
                raise ValueError(f'Dictionary record {index}: frequency must be a nonnegative integer')
            count = int(raw_count)
            if count:
                counts[word] = counts.get(word, 0) + count
    return UnigramDictionary.from_counts(counts)


def tokenize_sentence(sentence, dictionary):
    tokens = []
    for match in FRAGMENTS.finditer(sentence):
        fragment = match.group()
        if match.lastgroup == 'han':
            # An exact lower bound avoids a huge Viterbi table for a fragment
            # that cannot fit even with every token at maximum dictionary length.
            if len(fragment) > (MAX_WORDS - len(tokens)) * dictionary.max_word_length:
                return None
            tokens.extend(dictionary.segment(fragment))
        else:
            tokens.append(fragment.lower() if match.lastgroup == 'english' else fragment)
        if len(tokens) > MAX_WORDS:
            return None
    return tokens


_DICTIONARY = None
_PUNCTUATION = SENTENCE_PUNCTUATION
_TRACK_ORIGINS = False


def initialize_worker(dictionary, punctuation, track_origins=False):
    global _DICTIONARY, _PUNCTUATION, _TRACK_ORIGINS
    _DICTIONARY, _PUNCTUATION, _TRACK_ORIGINS = dictionary, punctuation, track_origins


def process_chunk(task):
    first_line, raw_lines = task
    output = io.StringIO()
    positions = [] if _TRACK_ORIGINS else None
    kept = empty = too_long = 0
    for offset, raw in enumerate(raw_lines):
        try:
            text = normalize_line(raw.decode('utf-8'))
        except UnicodeError:
            raise ValueError(f'Input is not valid UTF-8 at line {first_line + offset}') from None
        if not text.strip():
            empty += 1
            continue
        for sentence_index, sentence in enumerate(sentences(text, _PUNCTUATION), 1):
            tokens = tokenize_sentence(sentence, _DICTIONARY)
            if tokens is None:
                too_long += 1
            elif tokens:
                output.write(' '.join(tokens) + '\n')
                if positions is not None:
                    positions.append((first_line + offset, sentence_index))
                kept += 1
    return output.getvalue(), len(raw_lines), sum(map(len, raw_lines)), kept, empty, too_long, positions


def line_chunks(handle, chunk_lines, chunk_bytes):
    lines = []
    size = 0
    first_line = 1
    for raw in handle:
        if lines and (len(lines) >= chunk_lines or size + len(raw) > chunk_bytes):
            yield first_line, tuple(lines)
            first_line += len(lines)
            lines, size = [], 0
        lines.append(raw)
        size += len(raw)
    if lines:
        yield first_line, tuple(lines)


class Progress:
    def __init__(self, size, quiet):
        self.size, self.quiet = size, quiet
        self.lines = self.bytes = self.kept = self.empty = self.too_long = 0
        self.started = time.monotonic()
        self.last_update = self.started - 5

    def show(self, final=False):
        now = time.monotonic()
        interval = 0.5 if sys.stderr.isatty() else 5.0
        if self.quiet or (not final and now - self.last_update < interval):
            return
        percentage = min(100, self.bytes * 100 / self.size) if self.size else 100.0
        message = (f'{percentage:6.2f}% | {self.lines:,} lines | {self.kept:,} sentences | '
                   f'{self.empty:,} empty lines | {self.too_long:,} over 100 tokens | '
                   f'{now - self.started:.1f}s')
        print(('\r' if sys.stderr.isatty() else '') + message,
              file=sys.stderr, end='\n' if final or not sys.stderr.isatty() else '', flush=True)
        self.last_update = now

    def consume(self, future, output, origins=None):
        while True:
            try:
                text, lines, size, kept, empty, too_long, positions = future.result(timeout=0.5)
                break
            except TimeoutError:
                if future.done():
                    raise
                self.show()
        output.write(text)
        if origins is not None:
            if positions is None or len(positions) != kept:
                raise ValueError('Output origin count differs from sentence count')
            for position in positions:
                origins.write(json.dumps(position, separators=(',', ':')) + '\n')
        self.lines += lines
        self.bytes += size
        self.kept += kept
        self.empty += empty
        self.too_long += too_long
        self.show()


def run(args):
    if not args.input.is_file() or not args.dictionary.is_file():
        raise ValueError('Input and dictionary must be existing regular files')
    origin_path = getattr(args, 'output_origins', None)
    targets = [args.output] + ([origin_path] if origin_path is not None else [])
    if len({path.resolve() for path in targets}) != len(targets):
        raise ValueError('Output text and origins must use different paths')
    for path in targets:
        if path.exists() or path.is_symlink():
            raise FileExistsError('Choose new output files; existing outputs are preserved')
    if not args.quiet:
        print('Loading unigram dictionary...', file=sys.stderr, flush=True)
    dictionary = load_dictionary(args.dictionary)
    if not args.quiet:
        print(f'{len(dictionary.log_probabilities):,} Han words; maximum length '
              f'{dictionary.max_word_length}; {args.workers} workers', file=sys.stderr, flush=True)
    temporary_files = []
    published = []
    try:
        with ExitStack() as stack:
            handles = []
            for path in targets:
                path.parent.mkdir(parents=True, exist_ok=True)
                descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
                temporary_files.append((Path(name), path))
                handles.append(stack.enter_context(os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n')))
            output = handles[0]
            origins = handles[1] if origin_path is not None else None
            source = stack.enter_context(args.input.open('rb'))
            progress = Progress(os.fstat(source.fileno()).st_size, args.quiet)
            progress.show()
            with ProcessPoolExecutor(max_workers=args.workers, mp_context=multiprocessing.get_context('spawn'),
                                     initializer=initialize_worker,
                                     initargs=(dictionary, frozenset(args.sentence_punctuation), origins is not None)) as pool:
                pending = deque()
                try:
                    for task in line_chunks(source, args.chunk_lines, args.chunk_bytes):
                        pending.append(pool.submit(process_chunk, task))
                        if len(pending) >= args.max_in_flight:
                            progress.consume(pending.popleft(), output, origins)
                    while pending:
                        progress.consume(pending.popleft(), output, origins)
                finally:
                    for future in pending:
                        future.cancel()
        # A same-directory hard link atomically publishes without replacing a
        # destination created by another process while this job was running.
        progress.show(final=True)
        for temporary, target in temporary_files:
            os.link(temporary, target)
            published.append((temporary, target))
        return progress
    except BaseException:
        for temporary, target in published:
            if target.exists() and os.path.samestat(temporary.stat(), target.stat()):
                target.unlink()
        raise
    finally:
        for temporary, _ in temporary_files:
            temporary.unlink(missing_ok=True)


def positive_integer(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('must be positive')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True, help='UTF-8 text, one source line per record')
    parser.add_argument('--output', type=Path, required=True, help='New UTF-8 output file; never overwrites')
    parser.add_argument('--output-origins', type=Path,
                        help='Optional JSONL [input_line, sentence_index] map, one pair per output sentence')
    parser.add_argument('--dictionary', type=Path, required=True, help='CSV/TSV text,count or plain word/count pairs')
    parser.add_argument('--workers', type=positive_integer, default=min(8, max(1, (os.cpu_count() or 2) - 1)))
    parser.add_argument('--chunk-lines', type=positive_integer, default=1000)
    parser.add_argument('--chunk-bytes', type=positive_integer, default=1024 * 1024)
    parser.add_argument('--max-in-flight', type=positive_integer,
                        help='Maximum submitted chunks retained in memory; default twice the worker count')
    parser.add_argument('--sentence-punctuation', default=''.join(sorted(SENTENCE_PUNCTUATION)),
                        help='Boundary symbols; decimals and English word punctuation remain protected')
    parser.add_argument('--quiet', action='store_true', help='Suppress stderr progress')
    args = parser.parse_args()
    if args.max_in_flight is None:
        args.max_in_flight = 2 * args.workers
    try:
        run(args)
    except (OSError, ValueError, csv.Error, RuntimeError) as error:
        parser.exit(1, f'Tokenization error: {error}\n')
    except KeyboardInterrupt:
        parser.exit(130, 'Tokenization interrupted.\n')


if __name__ == '__main__':
    main()
