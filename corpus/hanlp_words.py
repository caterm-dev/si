#!/usr/bin/env python3
"""Locally segment frozen Chinese bundles and count words, separately per source."""

import argparse
from collections import Counter
import csv
import gzip
import importlib.metadata
import itertools
import json
import os
from pathlib import Path
import socket
import time

if __package__:
    from .common import ROOT, digest, new_directory, write_json
else:
    from common import ROOT, digest, new_directory, write_json

CACHE = ROOT / '.cache' / 'hanlp'
MODEL = 'https://file.hankcs.com/hanlp/tok/coarse_electra_small_20220616_012050.zip'
PACKAGES = ('hanlp', 'hanlp-common', 'hanlp-trie', 'torch', 'transformers', 'tokenizers')


def configure_cache():
    # All downloads and writable caches stay within the ignored corpus workspace.
    os.environ['HANLP_HOME'] = str(CACHE)
    os.environ['HF_HOME'] = str(ROOT / '.cache' / 'huggingface')
    os.environ['TORCH_HOME'] = str(ROOT / '.cache' / 'torch')
    os.environ['TOKENIZERS_PARALLELISM'] = 'false'


def versions():
    return {name: importlib.metadata.version(name) for name in PACKAGES}


def model_files():
    return {str(p.relative_to(CACHE)): digest(p)
            for p in sorted(CACHE.rglob('*'))
            if p.is_file() and p.name != 'model-lock.json' and not p.name.endswith('.downloading')}


def fetch():
    import hanlp
    hanlp.load(MODEL, devices=-1)
    write_json(CACHE / 'model-lock.json', {
        'schema_version': 1, 'url': MODEL, 'packages': versions(), 'files': model_files(),
        'model_terms': 'HanLP Chinese pretrained models: research/teaching only unless separately specified. '
                       'Model remains a local analysis tool and is not bundled with SI.',
    })
    print('Local model and dependency hashes recorded.', flush=True)


def no_network(*args, **kwargs):
    raise OSError('Segmentation is offline. Run the explicit fetch command to prepare model assets.')


def load_tokenizer(device, threads):
    lock = json.loads((CACHE / 'model-lock.json').read_text())
    if lock['url'] != MODEL or lock['packages'] != versions() or lock['files'] != model_files():
        raise ValueError('Model assets/dependencies differ from the fetched lock')
    # Fail closed even if a dependency tries to fetch a missing ancillary asset.
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    socket.socket.connect = no_network
    socket.create_connection = no_network
    import hanlp
    import torch
    torch.set_num_threads(threads)
    tok = hanlp.load(str(CACHE / 'tok' / Path(MODEL).stem), devices=-1)
    if device == 'mps' and not torch.backends.mps.is_available():
        raise ValueError('MPS is unavailable; choose --device cpu')
    tok.model.to(torch.device(device))
    tok.model.eval()
    # No SI vocabulary is forced into the segmenter: statistics remain independent.
    tok.dict_force = tok.dict_combine = None
    return tok, lock


def write_counts(path, counts, lines):
    with path.open('w', encoding='utf-8', newline='') as handle:
        writer = csv.writer(handle, lineterminator='\n')
        writer.writerow(['text', 'count', 'line_count'])
        writer.writerows((word, count, lines[word]) for word, count in
                         sorted(counts.items(), key=lambda item: (-item[1], item[0])))


def count_tokens(texts, tokenized, counts, line_counts):
    if len(texts) != len(tokenized):
        raise ValueError('Tokenizer changed the number of input fragments')
    for text, tokens in zip(texts, tokenized, strict=True):
        if not tokens or any(not isinstance(t, str) or not t for t in tokens) or ''.join(tokens) != text:
            raise ValueError('Tokenizer changed input bytes or returned an invalid boundary')
        counts.update(tokens)
        line_counts.update(set(tokens))


def tokenize_chunk(tok, texts, batch_size):
    # Group similar lengths to avoid padding short dialogue to long-fragment size.
    # Explicitly disable the model's saved 32-item training sampler, then restore
    # exact source order before recording any tokens or counts.
    order = sorted(range(len(texts)), key=lambda index: len(texts[index]))
    results = [None] * len(texts)
    for start in range(0, len(order), batch_size):
        indices = order[start:start + batch_size]
        batch = [texts[index] for index in indices]
        predictions = tok(batch, batch_size=batch_size, sampler_builder=None)
        if len(predictions) != len(indices):
            raise ValueError('Tokenizer changed the number of input fragments')
        for index, prediction in zip(indices, predictions, strict=True):
            results[index] = prediction
    return results


def source_inputs(bundles):
    result = []
    seen = set()
    for bundle in bundles:
        manifest = json.loads((bundle / 'manifest.json').read_text())
        if digest(bundle / 'sources.lock.json') != manifest['source_lock_sha256']:
            raise ValueError('Source lock checksum mismatch')
        for source in manifest['sources']:
            name = source['source']['id']
            if name in seen:
                raise ValueError('Repeated source; choose exactly one frozen version: ' + name)
            seen.add(name)
            for file in ('text.txt', 'origins.jsonl'):
                expected = source['files'][file]
                path = bundle / name / file
                if path.stat().st_size != expected['bytes'] or digest(path) != expected['sha256']:
                    raise ValueError('Source checksum mismatch: ' + name + '/' + file)
            result.append((bundle / name, source))
    return result


def segment(args):
    inputs = source_inputs(args.bundle)
    tok, lock = load_tokenizer(args.device, args.threads)
    args.output.mkdir(parents=True, exist_ok=True)
    configuration = {
        'schema_version': 1, 'model': lock, 'device': args.device, 'threads': args.threads,
        'batch_size': args.batch_size, 'chunk_lines': args.chunk_lines,
        'script_sha256': digest(Path(__file__)),
        'sources': [source for _, source in inputs],
        'scope': 'All lines of the explicitly selected prepared bundles; not complete raw archives. '
                 'Counts reflect deduplicated Han fragments, not population frequencies.',
    }
    configuration_path = args.output / 'configuration.json'
    if configuration_path.exists():
        if json.loads(configuration_path.read_text()) != configuration:
            raise ValueError('Existing output configuration differs; choose a new output directory')
    else:
        if any(args.output.iterdir()):
            raise ValueError('Nonempty output has no configuration')
        write_json(configuration_path, configuration)
    source_reports = []
    started = time.monotonic()
    for directory, source in inputs:
        name = source['source']['id']
        target = args.output / name
        target.mkdir(exist_ok=True)
        total_counts, total_lines = Counter(), Counter()
        processed = characters = tokens_total = 0
        chunks = []
        with (directory / 'text.txt').open(encoding='utf-8') as handle:
            for chunk_index in itertools.count():
                texts = [line.rstrip('\n') for line in itertools.islice(handle, args.chunk_lines)]
                if not texts:
                    break
                chunk_path = target / f'{chunk_index:05d}'
                if not chunk_path.exists():
                    with new_directory(chunk_path) as stage:
                        counts, line_counts = Counter(), Counter()
                        predictions = tokenize_chunk(tok, texts, args.batch_size)
                        count_tokens(texts, predictions, counts, line_counts)
                        with gzip.open(stage / 'tokens.jsonl.gz', 'wt', encoding='utf-8') as output:
                            for prediction in predictions:
                                output.write(json.dumps(prediction, ensure_ascii=False, separators=(',', ':')) + '\n')
                        write_counts(stage / 'counts.csv', counts, line_counts)
                        write_json(stage / 'manifest.json', {
                            'first_line': processed + 1, 'lines': len(texts),
                            'characters': sum(map(len, texts)), 'tokens': sum(counts.values()),
                            'files': {file: digest(stage / file) for file in ('tokens.jsonl.gz', 'counts.csv')},
                        })
                report = json.loads((chunk_path / 'manifest.json').read_text())
                if report['first_line'] != processed + 1 or report['lines'] != len(texts):
                    raise ValueError('Chunk line alignment mismatch')
                for file, expected in report['files'].items():
                    if digest(chunk_path / file) != expected:
                        raise ValueError('Completed chunk checksum mismatch')
                with (chunk_path / 'counts.csv').open(encoding='utf-8') as counts_file:
                    for row in csv.DictReader(counts_file):
                        total_counts[row['text']] += int(row['count'])
                        total_lines[row['text']] += int(row['line_count'])
                processed += report['lines']
                characters += report['characters']
                tokens_total += report['tokens']
                chunks.append(report)
                elapsed = time.monotonic() - started
                print(f'{name}: {processed:,}/{source["counts"]["lines"]:,} lines; '
                      f'{tokens_total:,} tokens; elapsed {elapsed:.0f}s', flush=True)
        if processed != source['counts']['lines'] or characters != source['counts']['characters']:
            raise ValueError('Source count mismatch: ' + name)
        write_counts(target / 'counts.csv', total_counts, total_lines)
        report = {'id': name, 'lines': processed, 'characters': characters,
                  'tokens': tokens_total, 'types': len(total_counts), 'chunks': chunks,
                  'counts_sha256': digest(target / 'counts.csv'),
                  'source': source['source'], 'input_files': source['files']}
        write_json(target / 'manifest.json', report)
        source_reports.append(report)
    write_json(args.output / 'manifest.json', {
        'schema_version': 1, 'configuration_sha256': digest(configuration_path),
        'sources': source_reports,
        'total_lines': sum(s['lines'] for s in source_reports),
        'total_characters': sum(s['characters'] for s in source_reports),
        'total_tokens': sum(s['tokens'] for s in source_reports),
    })


def verify(args):
    """Independently recount token files and compare every boundary with source text."""
    inputs = source_inputs(args.bundle)
    manifest = json.loads((args.output / 'manifest.json').read_text())
    config_path = args.output / 'configuration.json'
    config = json.loads(config_path.read_text())
    if (manifest['configuration_sha256'] != digest(config_path)
            or config['sources'] != [source for _, source in inputs]):
        raise ValueError('Segmentation configuration/source mismatch')
    expected_sources = {s['id']: s for s in manifest['sources']}
    if set(expected_sources) != {s['source']['id'] for _, s in inputs}:
        raise ValueError('Segmentation source set mismatch')
    total_lines = total_characters = total_tokens = 0
    for directory, source in inputs:
        name = source['source']['id']
        target = args.output / name
        report = expected_sources[name]
        if json.loads((target / 'manifest.json').read_text()) != report:
            raise ValueError('Source report mismatch')
        counts, line_counts = Counter(), Counter()
        lines = characters = 0
        with (directory / 'text.txt').open(encoding='utf-8') as text_file:
            for index, chunk in enumerate(report['chunks']):
                chunk_path = target / f'{index:05d}'
                if json.loads((chunk_path / 'manifest.json').read_text()) != chunk:
                    raise ValueError('Chunk report mismatch')
                for file, expected in chunk['files'].items():
                    if digest(chunk_path / file) != expected:
                        raise ValueError('Chunk checksum mismatch')
                chunk_counts, chunk_lines = Counter(), Counter()
                measured_lines = measured_chars = 0
                with gzip.open(chunk_path / 'tokens.jsonl.gz', 'rt', encoding='utf-8') as tokens:
                    for line in tokens:
                        text = next(text_file, '').rstrip('\n')
                        count_tokens([text], [json.loads(line)], chunk_counts, chunk_lines)
                        measured_lines += 1
                        measured_chars += len(text)
                if (chunk['first_line'] != lines + 1 or measured_lines != chunk['lines']
                        or measured_chars != chunk['characters'] or sum(chunk_counts.values()) != chunk['tokens']):
                    raise ValueError('Recounted chunk totals differ')
                counts.update(chunk_counts)
                line_counts.update(chunk_lines)
                lines += measured_lines
                characters += measured_chars
            if next(text_file, None) is not None:
                raise ValueError('Unsegmented source remainder')
        if digest(target / 'counts.csv') != report['counts_sha256']:
            raise ValueError('Source count checksum mismatch')
        with (target / 'counts.csv').open(encoding='utf-8') as count_file:
            rows = list(csv.DictReader(count_file))
        actual = {row['text']: (int(row['count']), int(row['line_count'])) for row in rows}
        if (len(actual) != len(rows) or actual != {word: (count, line_counts[word]) for word, count in counts.items()}
                or lines != source['counts']['lines'] or characters != source['counts']['characters']
                or report['lines'] != lines or report['characters'] != characters
                or report['tokens'] != sum(counts.values()) or report['types'] != len(counts)):
            raise ValueError('Recounted source totals differ')
        total_lines += lines
        total_characters += characters
        total_tokens += sum(counts.values())
        print(f'Verified {name}: {lines:,} exact fragments / {sum(counts.values()):,} tokens', flush=True)
    if (manifest['total_lines'], manifest['total_characters'], manifest['total_tokens']) != (
            total_lines, total_characters, total_tokens):
        raise ValueError('Recounted collection totals differ')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('fetch', help='Explicitly download and lock the local pretrained segmenter')
    command = sub.add_parser('verify', help='Independently recount all tokens and verify exact source boundaries')
    command.add_argument('--bundle', type=Path, action='append', required=True)
    command.add_argument('--output', type=Path, required=True)
    command = sub.add_parser('segment', help='Segment all selected prepared text, offline; resume complete chunks')
    command.add_argument('--bundle', type=Path, action='append', required=True)
    command.add_argument('--output', type=Path, required=True)
    command.add_argument('--device', choices=('cpu', 'mps'), default='cpu')
    command.add_argument('--threads', type=int, default=4)
    command.add_argument('--batch-size', type=int, default=256)
    command.add_argument('--chunk-lines', type=int, default=25000)
    args = parser.parse_args()
    if args.command == 'segment' and min(args.threads, args.batch_size, args.chunk_lines) < 1:
        parser.error('Thread, batch and chunk sizes must be positive')
    configure_cache()
    if args.command == 'fetch':
        fetch()
    elif args.command == 'verify':
        verify(args)
    else:
        segment(args)


if __name__ == '__main__':
    main()
