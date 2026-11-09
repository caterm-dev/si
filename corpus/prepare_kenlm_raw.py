#!/usr/bin/env python3
"""Run the shared unigram tokenizer on complete raw-derived text and verify lineage."""

import argparse
from contextlib import redirect_stderr
import itertools
import json
import os
from pathlib import Path
import platform
import shutil
import tempfile
import time
from types import SimpleNamespace
import unicodedata

if __package__:
    from .common import CHINESE, ROOT, digest, load_sources, new_directory, write_json
    from . import tokenize_unigram as tokenizer
else:
    from common import CHINESE, ROOT, digest, load_sources, new_directory, write_json
    import tokenize_unigram as tokenizer

BOUNDARIES = '。！？.!?'
REFERENCE = CHINESE / 'dictionaries/generated/unigram-words-v2/frequencies.csv'
_VERIFICATION_TRANSLATION = None


def normalize_for_verification(text):
    """Independently express the normalizer with a reusable Unicode translation table."""
    global _VERIFICATION_TRANSLATION
    if _VERIFICATION_TRANSLATION is None:
        table = {}
        for value in range(0x110000):
            character = chr(value)
            if character.isspace():
                table[value] = ' '
            elif unicodedata.category(character) in ('Cc', 'Cf', 'Cs'):
                table[value] = None
        for start, end in tokenizer.INVISIBLE_RANGES:
            for value in range(start, end + 1):
                if not chr(value).isspace():
                    table[value] = None
        _VERIFICATION_TRANSLATION = table
    return unicodedata.normalize('NFKC', text).translate(_VERIFICATION_TRANSLATION)


def recorded_path(path):
    path = path.resolve()
    return str(path.relative_to(ROOT.parent)) if path.is_relative_to(ROOT.parent) else str(path)


def verify_source(input_text, output_text, output_origins, dictionary):
    counts = {'input_lines': 0, 'empty_lines': 0, 'candidate_sentences': 0,
              'sentences': 0, 'tokens': 0, 'over_100_tokens': 0, 'maximum_sentence_tokens': 0,
              'sentences_with_digits': 0, 'sentences_with_english': 0}
    last_report = time.monotonic()
    with input_text.open('rb') as source, output_text.open('rb') as output, \
            output_origins.open(encoding='utf-8') as origins:
        def records():
            previous = (0, 0)
            for raw, position in itertools.zip_longest(output, origins):
                if raw is None or position is None:
                    raise ValueError('Output/origin line counts differ')
                parsed = json.loads(position)
                if (not isinstance(parsed, list) or len(parsed) != 2
                        or any(type(value) is not int or value < 1 for value in parsed)):
                    raise ValueError('Invalid sentence origin')
                key = tuple(parsed)
                if key <= previous:
                    raise ValueError('Sentence origins are not strictly ordered')
                previous = key
                yield key, raw

        stream = records()
        pending = next(stream, None)
        for line_number, raw in enumerate(source, 1):
            counts['input_lines'] += 1
            normalized = normalize_for_verification(raw.decode('utf-8'))
            if line_number % 10000 == 0 and time.monotonic() - last_report >= 15:
                print(f'Verified {line_number:,} raw input lines / {counts["sentences"]:,} sentences', flush=True)
                last_report = time.monotonic()
            if not normalized.strip():
                counts['empty_lines'] += 1
                continue
            for sentence_index, sentence in enumerate(tokenizer.sentences(normalized, frozenset(BOUNDARIES)), 1):
                counts['candidate_sentences'] += 1
                expected_key = (line_number, sentence_index)
                if pending is None or pending[0] > expected_key:
                    if tokenizer.tokenize_sentence(sentence, dictionary) is not None:
                        raise ValueError('A source sentence was lost without the >100-token filter')
                    counts['over_100_tokens'] += 1
                    continue
                if pending[0] != expected_key:
                    raise ValueError('Sentence origin points outside the current source sentence')
                raw_output = pending[1]
                if not raw_output.endswith(b'\n') or b'\r' in raw_output or b'\t' in raw_output:
                    raise ValueError('Invalid output newline/whitespace')
                value = raw_output[:-1].decode('utf-8')
                words = value.split(' ')
                if (not value or any(not word or any(c.isspace() for c in word) for word in words)
                        or len(words) > tokenizer.MAX_WORDS
                        or not set(words).isdisjoint({'<s>', '</s>', '<unk>'})):
                    raise ValueError('Invalid token spacing, length or reserved marker')
                fragments = list(tokenizer.FRAGMENTS.finditer(sentence))
                expected_text = ''.join(match.group().lower() if match.lastgroup == 'english'
                                        else match.group() for match in fragments)
                if ''.join(words) != expected_text:
                    raise ValueError('NFKC source characters, numbers or punctuation changed')
                counts['sentences'] += 1
                counts['tokens'] += len(words)
                counts['maximum_sentence_tokens'] = max(counts['maximum_sentence_tokens'], len(words))
                counts['sentences_with_digits'] += any(match.lastgroup == 'number' for match in fragments)
                counts['sentences_with_english'] += any(match.lastgroup == 'english' for match in fragments)
                pending = next(stream, None)
        if pending is not None:
            raise ValueError('Output contains an unmatched extra sentence')
    return counts


def tokenize_source(source, input_root, output_root, dictionary_path, workers):
    name = source['id']
    prepared = input_root / name
    extraction = json.loads((prepared / 'manifest.json').read_text())
    if (extraction.get('extraction_contract') not in (
            'complete-raw-text-lines-v1', 'complete-simplified-text-lines-v2')
            or extraction['source'] != source):
        raise ValueError('Input is not the complete raw-text extraction: ' + name)
    for file, expected in extraction['files'].items():
        if digest(prepared / file) != expected['sha256']:
            raise ValueError('Raw-derived input checksum mismatch: ' + name)
    identity = {'raw_text_manifest_sha256': digest(prepared / 'manifest.json'),
                'tokenizer_sha256': digest(ROOT / 'tokenize_unigram.py'),
                'dictionary_sha256': digest(dictionary_path), 'sentence_punctuation': BOUNDARIES}
    target = output_root / name
    if target.exists():
        record = json.loads((target / 'manifest.json').read_text())
        if record['identity'] != identity:
            raise ValueError('Completed source uses different input/tokenizer/dictionary: ' + name)
        for file, expected in record['files'].items():
            if digest(target / file) != expected['sha256']:
                raise ValueError('Completed source checksum mismatch: ' + name)
        print('Verified completed tokenization: ' + name, flush=True)
        return record
    print('Tokenizing complete raw-derived source: ' + name, flush=True)
    with new_directory(target) as stage:
        args = SimpleNamespace(input=prepared / 'text.txt', output=stage / 'text.txt',
                               output_origins=stage / 'origins.jsonl', dictionary=dictionary_path,
                               workers=workers, chunk_lines=1000, chunk_bytes=1048576,
                               max_in_flight=2 * workers, sentence_punctuation=BOUNDARIES, quiet=False)
        with (stage / 'tokenize.log').open('w') as log, redirect_stderr(log):
            progress = tokenizer.run(args)
        print('Independently verifying source sentences: ' + name, flush=True)
        dictionary = tokenizer.load_dictionary(dictionary_path)
        measured = verify_source(prepared / 'text.txt', stage / 'text.txt', stage / 'origins.jsonl', dictionary)
        if (measured['input_lines'], measured['sentences'], measured['empty_lines'], measured['over_100_tokens']) != (
                progress.lines, progress.kept, progress.empty, progress.too_long):
            raise ValueError('Independent counters disagree with tokenization: ' + name)
        if identity != {'raw_text_manifest_sha256': digest(prepared / 'manifest.json'),
                        'tokenizer_sha256': digest(ROOT / 'tokenize_unigram.py'),
                        'dictionary_sha256': digest(dictionary_path), 'sentence_punctuation': BOUNDARIES}:
            raise ValueError('Inputs/code changed during source processing')
        record = {'schema_version': 1, 'id': name, 'source': source, 'identity': identity,
                  'raw_text_directory': recorded_path(prepared),
                  'dictionary': recorded_path(dictionary_path),
                  'python': platform.python_version(), 'unicode': unicodedata.unidata_version,
                  'workers': workers, 'counts': measured,
                  'origin_format': '[one-based raw-text input line, one-based sentence index within line]; '
                                   'raw-text documents.jsonl maps input lines to raw record/turn/page/path',
                  'files': {file: {'sha256': digest(stage / file), 'bytes': (stage / file).stat().st_size}
                            for file in ('text.txt', 'origins.jsonl')}}
        write_json(stage / 'manifest.json', record)
    print(f'Completed {name}: {measured["sentences"]:,} sentences / {measured["tokens"]:,} tokens; '
          f'{measured["over_100_tokens"]:,} over-limit sentences filtered', flush=True)
    return record


def finalize(sources, input_root, output_root):
    records = [json.loads((output_root / source['id'] / 'manifest.json').read_text()) for source in sources]
    if len({record['identity']['dictionary_sha256'] for record in records}) != 1:
        raise ValueError('Sources use different unigram dictionaries')
    for source, record in zip(sources, records, strict=True):
        if source != record['source']:
            raise ValueError('Completed source pin mismatch')
        for file, expected in record['files'].items():
            path = output_root / source['id'] / file
            if digest(path) != expected['sha256']:
                raise ValueError('Completed token file checksum mismatch')
    combined = output_root / 'kenlm-input.txt'
    ranges = []
    first_line = 1
    byte_offset = 0
    for record in records:
        count = record['counts']['sentences']
        ranges.append({'source': record['id'], 'first_line': first_line, 'lines': count,
                       'byte_offset': byte_offset, 'bytes': record['files']['text.txt']['bytes'],
                       'sha256': record['files']['text.txt']['sha256']})
        first_line += count
        byte_offset += record['files']['text.txt']['bytes']
    if not combined.exists():
        if shutil.disk_usage(output_root).free < byte_offset + 1024 * 1024 * 1024:
            raise OSError('Insufficient free space for the combined input; per-source results are retained')
        descriptor, name = tempfile.mkstemp(prefix='.kenlm-input-', dir=output_root)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, 'wb') as output:
                for record in records:
                    with (output_root / record['id'] / 'text.txt').open('rb') as source_file:
                        shutil.copyfileobj(source_file, output, length=1024 * 1024)
            os.link(temporary, combined)
        finally:
            temporary.unlink(missing_ok=True)
    import hashlib
    with combined.open('rb') as handle:
        for expected in ranges:
            checksum = hashlib.sha256()
            remaining = expected['bytes']
            while remaining:
                block = handle.read(min(1024 * 1024, remaining))
                if not block:
                    raise ValueError('Truncated combined file')
                checksum.update(block)
                remaining -= len(block)
            if checksum.hexdigest() != expected['sha256']:
                raise ValueError('Combined source byte range differs')
        if handle.read(1):
            raise ValueError('Unexpected extra bytes in combined file')
    attribution = output_root / 'attribution'
    attribution.mkdir(exist_ok=True)
    for file in ('sources.lock.json', 'NOTICE.md'):
        shutil.copy2(CHINESE / file, attribution / file)
    for directory in ('licenses', 'metadata'):
        if not (attribution / directory).exists():
            shutil.copytree(CHINESE / directory, attribution / directory)
    totals = {key: sum(record['counts'][key] for record in records) for key in
              ('input_lines', 'empty_lines', 'candidate_sentences', 'sentences', 'tokens',
               'over_100_tokens', 'sentences_with_digits', 'sentences_with_english')}
    manifest = {'schema_version': 1, 'contract': 'complete-raw-to-unigram-kenlm-v1',
                'created_on': '2026-11-05', 'sources': records, 'source_ranges': ranges,
                'totals': totals, 'maximum_sentence_tokens': max(r['counts']['maximum_sentence_tokens'] for r in records),
                'combined': {'path': 'kenlm-input.txt', 'bytes': combined.stat().st_size, 'sha256': digest(combined)},
                'scope': 'Complete pinned local raw archives; no character cap, deduplication or 4–96 Han cutting. '
                         'Numbers/English/punctuation retained after NFKC; commas/enumeration commas stay within sentences. '
                         'Original scripts are preserved without simplification. Markup extraction remains heuristic.',
                'training_started': False, 'split_assignment': None,
                'data_terms': 'Each source retains its own terms; combination does not relicense the text. '
                              'Per-source text, sentence lineage and raw document ranges are retained.'}
    dictionary_path = ROOT.parent / records[0]['dictionary']
    dictionary_manifest = dictionary_path.parent / 'manifest.json'
    manifest['dictionary'] = {'path': records[0]['dictionary'],
                              'sha256': records[0]['identity']['dictionary_sha256']}
    if dictionary_manifest.exists():
        manifest['dictionary']['provenance'] = json.loads(dictionary_manifest.read_text())
        manifest['dictionary']['provenance_sha256'] = digest(dictionary_manifest)
    temporary = output_root / '.manifest.json.tmp'
    write_json(temporary, manifest)
    temporary.replace(output_root / 'manifest.json')
    print(json.dumps(totals, ensure_ascii=False), flush=True)
    print('Published raw-derived KenLM input: ' + str(combined), flush=True)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('tokenize', 'finalize'))
    parser.add_argument('--source', default='all')
    parser.add_argument('--input-root', type=Path, default=CHINESE / 'prepared/raw-text-v1')
    parser.add_argument('--output-root', type=Path, default=CHINESE / 'generated/kenlm-words-v2')
    parser.add_argument('--dictionary', type=Path, default=REFERENCE)
    parser.add_argument('--workers', type=tokenizer.positive_integer, default=4)
    args = parser.parse_args()
    sources = load_sources()
    if args.source not in {'all', *(source['id'] for source in sources)}:
        parser.error('Unknown source')
    args.output_root.mkdir(parents=True, exist_ok=True)
    if args.command == 'finalize':
        if args.source != 'all':
            parser.error('Finalization requires all sources')
        finalize(sources, args.input_root, args.output_root)
    else:
        for source in sources:
            if args.source in ('all', source['id']):
                tokenize_source(source, args.input_root, args.output_root, args.dictionary, args.workers)


if __name__ == '__main__':
    main()
