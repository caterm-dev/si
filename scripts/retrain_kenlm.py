#!/usr/bin/env python3
"""Retokenize frozen public raw-text-v2 with current SI counts and refit KenLM."""

import argparse
from collections import Counter
import csv
import itertools
import json
from pathlib import Path
import re
import shutil
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'corpus'))
import kenlm_train as training
import prepare_kenlm_raw as preparation
import tokenize_unigram as tokenizer
import kenlm_cleaning as cleaning
import kenlm_final as final

SOURCES = ('lccc', 'mc4', 'kubernetes', 'tensorflow', 'mdn', 'si', 'dialogue')
DEFAULT_RUN = ROOT / '.build/kenlm-dictionary-v3-20261110'
TOOLS = ROOT / 'corpus/.cache/kenlm-build/bin'
PRUNE = [0, 0, 1, 2]


def record(path):
    return {'path': str(path.relative_to(ROOT)), 'bytes': path.stat().st_size,
            'sha256': training.digest(path)}


def snapshot(run, language, destination):
    source = ROOT / 'Data' / language
    stamp = run / (destination.name + '-snapshot.json')
    if not destination.exists():
        before = tokenizer.dictionary_digest(source)
        with training.staged(destination) as stage:
            for path in sorted(source.glob('*.csv')):
                if path.is_symlink():
                    raise ValueError('Dictionary snapshot inputs must not be symbolic links')
                shutil.copyfile(path, stage / path.name)
            if before != tokenizer.dictionary_digest(stage) or before != tokenizer.dictionary_digest(source):
                raise ValueError('Dictionary changed during snapshot')
        training.save(stamp, {'source': str(source.relative_to(ROOT)), 'sha256': before,
                             'contract': 'si-count-csv-v3', 'files': [record(p) for p in sorted(destination.glob('*.csv'))]})
    expected = json.loads(stamp.read_text())['sha256']
    if tokenizer.dictionary_digest(destination) != expected:
        raise ValueError('Frozen dictionary changed')
    if tokenizer.dictionary_digest(source) != expected:
        raise ValueError('Current vocabulary differs from this run; select a new --run')


def tokenize(run, raw, workers):
    snapshot(run, 'Chinese', run / 'dictionary')
    output = run / 'tokenized'
    output.mkdir(exist_ok=True)
    sources = [json.loads((raw / name / 'manifest.json').read_text())['source'] for name in SOURCES]
    for source in sources:
        preparation.tokenize_source(source, raw, output, run / 'dictionary', workers)
    result = preparation.finalize(sources, raw, output)
    result.update(contract='si-count-dictionary-raw-text-v2-20261110',
                  scope='Seven existing raw-text-v2 sources; fresh unigram segmentation from Data/Chinese counts. '
                        'No user history or new downloads.', excluded_sources=['wikipedia'])
    training.save(output / 'manifest.json', result)
    return result


def protected_words(run):
    result = set()
    for directory in (run / 'dictionary', run / 'english-dictionary'):
        for path in sorted(directory.glob('*.csv')):
            with path.open(encoding='utf-8-sig', newline='') as stream:
                result.update(row['text'] for row in csv.DictReader(stream))
    return result


def clean_selection(data, output, dictionary):
    if output.exists():
        result = json.loads((output / 'manifest.json').read_text())
        for name in ('train', 'heldout'):
            if training.digest(output / (name + '.txt')) != result[name]['sha256']:
                raise ValueError('Cleaned split changed')
        return result
    with training.staged(output) as stage:
        raw, _ = final.round3.count_split(data / 'train.txt')
        cache, _, _ = final.make_mapping(raw, dictionary)
        base = Counter()
        for word, count in raw.items():
            base[cleaning.base_token(word.decode('utf-8'))[0]] += count
        mapper = cleaning.FrozenMapper(base, dictionary, 5)
        with (stage / 'train-mapping.tsv').open('wb') as stream:
            stream.write(b'token\ttrain_count\tclean2\treason\n')
            for word in sorted(raw):
                mapped, reason = cache[word]
                stream.write(b'\t'.join((word, str(raw[word]).encode(), mapped,
                                          (reason or 'unchanged').encode())) + b'\n')
        result = {}
        for name in ('train', 'heldout'):
            counts = Counter()
            with (data / (name + '.txt')).open('rb') as source, (stage / (name + '.txt')).open('wb') as target:
                for line in source:
                    if cleaning.reject_line(line.decode('utf-8')):
                        counts['rejected_lines'] += 1
                        continue
                    words = line.split()
                    if not words:
                        continue
                    mapped = []
                    for word in words:
                        if word not in cache:
                            cache[word] = mapper.token(word)
                        token, reason = cache[word]
                        mapped.append(token)
                        if reason:
                            counts[reason] += 1
                    target.write(b' '.join(mapped) + b'\n')
                    counts['lines'] += 1
                    counts['tokens'] += len(mapped)
            result[name] = {**dict(counts), 'sha256': training.digest(stage / (name + '.txt'))}
        training.save(stage / 'manifest.json', result)
    return result


def command(run, args, source, output, log):
    result = training.run_command(args, source, output, log, run / 'commands.jsonl')
    if result['exit_code']:
        raise RuntimeError('KenLM command failed; see ' + str(log))
    return result


def fit(run, source, destination, name):
    identity = training.digest(source)
    if destination.exists():
        result = json.loads((destination / (name + '.result.json')).read_text())
        if (result['input_sha256'] != identity or result['prune'] != PRUNE
                or training.digest(destination / (name + '.bin')) != result['binary_sha256']):
            raise ValueError('Completed model input/options/binary changed')
        return result
    with training.staged(destination) as stage:
        arpa, binary = stage / (name + '.arpa'), stage / (name + '.bin')
        args = [TOOLS / 'lmplz', '-o', '4', '--prune', *map(str, PRUNE), '-S', '4G', '-T', stage]
        fit_result = training.run_command(args, source, arpa, stage / 'lmplz.log', run / 'commands.jsonl')
        fallback = False
        if fit_result['exit_code']:
            log = (stage / 'lmplz.log').read_text(errors='replace')
            if 'BadDiscount' not in log and '--discount_fallback' not in log:
                raise RuntimeError('lmplz failed; see ' + str(stage))
            fallback = True
            retry = command(run, [*args, '--discount_fallback'], source, arpa, stage / 'lmplz-fallback.log')
            fit_result['seconds'] += retry['seconds']
        header, counts = final.previous.arpa_header(arpa)
        (stage / 'arpa-header.txt').write_text(header)
        final.arpa_vocabulary(arpa)
        packed = command(run, [TOOLS / 'build_binary', '-a', '22', '-q', '8', '-b', '8', 'trie', arpa, binary],
                         Path('/dev/null'), stage / 'build.stdout', stage / 'build.log')
        result = {'order': 4, 'prune': PRUNE, 'a': 22, 'probability_bits': 8, 'backoff_bits': 8,
                  'input_sha256': identity, 'ngram_counts': counts,
                  'binary_sha256': training.digest(binary), 'binary_bytes': binary.stat().st_size,
                  'arpa_sha256': training.digest(arpa), 'training_seconds': fit_result['seconds'],
                  'binary_build_seconds': packed['seconds'], 'discount_fallback': fallback}
        training.save(stage / (name + '.result.json'), result)
    return result


def evaluate(run, binary, source, output, expected=None):
    output.mkdir(exist_ok=True)
    command(run, [TOOLS / 'query', '-v', 'summary', binary], source, output / 'stdout', output / 'stderr')
    result = training.parse_query((output / 'stdout').read_text() + '\n' + (output / 'stderr').read_text())
    if expected is not None and result['query_tokens'] != expected:
        raise ValueError('Evaluation sentence/token count mismatch')
    training.save(output / 'results.json', result)
    return result


def train(run):
    snapshot(run, 'Chinese', run / 'dictionary')
    snapshot(run, 'English', run / 'english-dictionary')
    manifest = json.loads((run / 'tokenized/manifest.json').read_text())
    if [source['id'] for source in manifest['sources']] != list(SOURCES):
        raise ValueError('Unexpected training source selection')
    tool_lock = json.loads((ROOT / 'corpus/kenlm/source.lock.json').read_text())
    for name, expected in tool_lock['binaries'].items():
        if training.digest(TOOLS / name) != expected['sha256']:
            raise ValueError('Pinned KenLM tool changed: ' + name)
    paths = [Path(__file__), ROOT / 'corpus/tokenize_unigram.py', ROOT / 'corpus/prepare_kenlm_raw.py',
             ROOT / 'corpus/kenlm_train.py', ROOT / 'corpus/kenlm/source.lock.json',
             ROOT / 'scripts/kenlm_round2.py', ROOT / 'scripts/kenlm_round3.py',
             ROOT / 'scripts/install_kenlm_model.py',
             ROOT / 'scripts/kenlm_final.py', ROOT / 'scripts/kenlm_cleaning.py',
             ROOT / 'Tests/KenLMTests/cleaning_vectors.json', ROOT / 'Tests/KenLMTests/final_sanity_sentences.json']
    paths += sorted((run / 'dictionary').glob('*.csv')) + sorted((run / 'english-dictionary').glob('*.csv'))
    pins = {str(path.relative_to(ROOT)): record(path) for path in paths}
    pin_path = run / 'input-code-pin.json'
    if pin_path.exists() and json.loads(pin_path.read_text()) != pins:
        raise ValueError('Code or dictionary changed; choose a fresh --run')
    training.save(pin_path, pins)
    segmentation = tokenizer.load_dictionary(run / 'dictionary')
    segmentation_record = {'contract': 'si-csv-count-unigram-v1',
                           'dictionary_sha256': tokenizer.dictionary_digest(run / 'dictionary'),
                           'han_word_forms': len(segmentation.log_probabilities),
                           'maximum_word_length': segmentation.max_word_length,
                           'unknown_natural_log_probability': segmentation.unknown_log_probability,
                           'denominator': 'Sum of all Chinese CSV counts, including non-Han rows',
                           'unknown_pseudocount': 0.5}
    del segmentation
    dictionary = protected_words(run)
    selection = run / 'selection'
    training.prepare(run / 'tokenized/kenlm-input.txt', selection)
    training.audit_blocks(selection)
    stats = clean_selection(selection / 'data', run / 'clean2', dictionary)
    smoke = run / 'smoke-data'
    smoke.mkdir(exist_ok=True)
    for name, count in [('train', 100000), ('heldout', 10000)]:
        with (run / 'clean2' / (name + '.txt')).open('rb') as source, (smoke / (name + '.txt')).open('wb') as output:
            output.writelines(itertools.islice(source, count))
    fit(run, smoke / 'train.txt', run / 'smoke', 'smoke')
    evaluate(run, run / 'smoke/smoke.bin', smoke / 'heldout.txt', run / 'smoke/evaluation')
    train_model = fit(run, run / 'clean2/train.txt', run / 'train-only', 'model')
    heldout = evaluate(run, run / 'train-only/model.bin', run / 'clean2/heldout.txt', run / 'train-only/evaluation',
                       stats['heldout']['lines'] + stats['heldout']['tokens'])
    destination = run / 'final'
    destination.mkdir(exist_ok=True)
    split = json.loads((selection / 'data/manifest.json').read_text())['splits']
    corpus = final.prepare(destination, inputs=tuple(selection / 'data' / (name + '.txt') for name in ('train', 'heldout')),
                           dictionary=dictionary, split_manifest=split)
    model = fit(run, destination / 'full.clean2.txt', run / 'final-model', 'final')
    for name in ('final.bin', 'final.arpa', 'final.result.json'):
        target = destination / name
        if not target.exists():
            target.hardlink_to(run / 'final-model' / name)
    sanity = final.sanity(destination, tokenizer_dictionary=run / 'dictionary', dictionary=dictionary, configs={'final': PRUNE})
    if not all(result['passed'] for result in sanity.values()):
        raise ValueError('Natural/reversed sentence sanity gate failed')
    marker_output = (destination / 'sanity/final-markers.stdout').read_text()
    reference = []
    for marker in ('<num>', '<oov>'):
        match = re.search(re.escape(marker) + r'=\d+\s+\d+\s+([-+\deE.]+)', marker_output)
        if not match:
            raise ValueError('Missing CLI marker probability for native verification')
        reference.append(float(match[1]))
    training.save(destination / 'sanity/native-reference.json',
                  {'model_sha256': model['binary_sha256'], 'log10_probabilities': reference})
    metadata = {'schema_version': 1, 'created_at': final.utc_now(), 'model': model, 'corpus': corpus,
                'cleaning': {'version': 'si-kenlm-cleaning-v1', 'module_sha256': training.digest(ROOT / 'scripts/kenlm_cleaning.py'),
                             'vectors_sha256': training.digest(ROOT / 'Tests/KenLMTests/cleaning_vectors.json'),
                             'unicode_version': unicodedata.unidata_version, 'maximum_scalars': 32, 'rare_threshold_exclusive': 5},
                'kenlm': {**tool_lock, 'binary_format_version': 5}, 'sources': manifest,
                'tokenizer_dictionary': json.loads((run / 'dictionary-snapshot.json').read_text()),
                'tokenization': segmentation_record,
                'train_only': {'model': train_model, 'heldout': heldout}, 'sanity': sanity,
                'functional_sanity_passed': True, 'independent_heldout_evaluation_performed': False,
                'evaluation_note': 'Fixed settings; exact-line disjoint block split does not establish document/dialogue independence. '
                                   'Final fit includes heldout; its sanity scores are not heldout metrics.'}
    if pins != {str(path.relative_to(ROOT)): record(path) for path in paths}:
        raise ValueError('Training inputs/code changed during run')
    training.save(destination / 'final.meta.json', metadata)
    training.save(run / 'completed.json', {'completed_at': final.utc_now(), 'model': record(destination / 'final.bin'),
                                         'metadata': record(destination / 'final.meta.json'), 'sanity_passed': True})
    from install_kenlm_model import publish
    retained = publish(destination / 'final.bin', destination / 'final.meta.json')
    print('Retained delivery model: ' + str(retained), flush=True)
    print('Completed new-vocabulary KenLM: ' + model['binary_sha256'], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=('all', 'tokenize', 'train'), default='all')
    parser.add_argument('--run', type=Path, default=DEFAULT_RUN)
    parser.add_argument('--raw', type=Path, default=ROOT / 'corpus/chinese/prepared/raw-text-v2')
    parser.add_argument('--workers', type=int, default=6)
    args = parser.parse_args()
    args.run = args.run.resolve()
    if not args.run.is_relative_to(ROOT / '.build'):
        parser.error('--run must stay under the ignored .build directory')
    if args.workers < 1:
        parser.error('--workers must be positive')
    args.run.mkdir(parents=True, exist_ok=True)
    if args.stage in ('all', 'tokenize'):
        tokenize(args.run, args.raw, args.workers)
    if args.stage in ('all', 'train'):
        train(args.run)


if __name__ == '__main__':
    main()
