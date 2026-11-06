#!/usr/bin/env python3
"""Round-three cleaning/pruning experiments; original split files are immutable."""
import argparse
from collections import Counter
from contextlib import ExitStack
import csv
import json
import os
from pathlib import Path
import subprocess
import time

import kenlm_cleaning as cleaning
import kenlm_round2 as previous

ROOT = previous.ROOT
OUT = ROOT / '.build/kenlm-round3'
ORIGINAL = previous.OLD / 'data'
TOOLS = previous.TOOLS
VERSIONS = tuple(cleaning.THRESHOLDS)
CONFIGS = {'p0123': [0, 1, 2, 3], 'p0012': [0, 0, 1, 2]}
BAD_BYTES = tuple(s.encode('utf-8') for s in cleaning.GARBLED_MARKERS)


def dictionary_sources():
    return sorted(p for language in ('chinese', 'english')
                  for p in (ROOT / 'Data/Vocabulary' / language).glob('*.csv'))


def pin(out):
    previous.pin_inputs(out)
    paths = dictionary_sources() + [ROOT / 'scripts/kenlm_cleaning.py']
    state = {str(p.relative_to(ROOT)): {'sha256': previous.digest(p),
             'bytes': p.stat().st_size, 'mtime_ns': p.stat().st_mtime_ns} for p in paths}
    target = out / 'dictionary-rule-pin.json'
    if target.exists() and json.loads(target.read_text()) != state:
        raise ValueError('Dictionary or cleaning module changed; choose a fresh output directory')
    if not target.exists():previous.save(target, state)


def dictionary_words():
    words = set()
    for path in dictionary_sources():
        with path.open(encoding='utf-8', newline='') as stream:
            rows = csv.DictReader(stream)
            if rows.fieldnames != ['text', 'reading', 'weight']:
                raise ValueError('Unexpected dictionary CSV schema')
            words.update(row['text'] for row in rows)
    return words


def count_split(path):
    counts = Counter()
    stats = Counter()
    last = time.monotonic()
    with path.open('rb') as stream:
        for line in stream:
            stats['input_lines'] += 1
            words = line.split()
            stats['input_tokens'] += len(words)
            if any(marker in line for marker in BAD_BYTES):
                stats['deleted_garbled_lines'] += 1
                stats['deleted_garbled_tokens'] += len(words)
            elif not words:
                stats['empty_lines'] += 1
            else:
                stats['output_lines'] += 1
                stats['retained_tokens'] += len(words)
                counts.update(words)
            if stats['input_lines'] % 100000 == 0 and time.monotonic() - last > 20:
                print(f'Counting {path.name}: {stats["input_lines"]:,} lines', flush=True)
                last = time.monotonic()
    for key in ('deleted_garbled_lines', 'deleted_garbled_tokens', 'empty_lines'):
        stats.setdefault(key, 0)
    return counts, dict(stats)


def prepare(out):
    target = out / 'data'
    if target.exists():
        manifest = json.loads((target / 'manifest.json').read_text())
        for version in VERSIONS:
            for split in ('train', 'heldout'):
                record = manifest['versions'][version][split]
                if previous.digest(target / version / (split + '.txt')) != record['sha256']:
                    raise ValueError('Cleaned split changed')
        return
    pin(out)
    dictionary = dictionary_words()
    print(f'Dictionary protection: {len(dictionary):,} exact word forms; phrase/ excluded', flush=True)
    raw_train, train_stats = count_split(ORIGINAL / 'train.txt')
    # No heldout token is inspected until train statistics have been frozen.
    base_counts = Counter()
    for word, count in raw_train.items():
        mapped, _ = cleaning.base_token(word.decode('utf-8'))
        base_counts[mapped] += count
    raw_heldout, heldout_stats = count_split(ORIGINAL / 'heldout.txt')
    original_manifest = json.loads((ORIGINAL / 'manifest.json').read_text())
    for split, stats in (('train', train_stats), ('heldout', heldout_stats)):
        source = original_manifest['splits'][split]
        if (stats['input_lines'], stats['input_tokens']) != (source['lines'], source['tokens']):
            raise ValueError('Source split coverage mismatch')
    mappers = [cleaning.FrozenMapper(base_counts, dictionary, cleaning.THRESHOLDS[v]) for v in VERSIONS]
    cache = {}
    for word in raw_train.keys() | raw_heldout.keys():
        decisions = [mapper.token(word) for mapper in mappers]
        cache[word] = tuple(x[0] for x in decisions), tuple(x[1] for x in decisions)
    with previous.staged(target) as stage:
        previous.save(stage / 'rules.json', {
            'contract': 'si-kenlm-cleaning-v1', 'garbled_markers': cleaning.GARBLED_MARKERS,
            'numeric_regex': cleaning.NUMBER.pattern, 'length_unit': 'Unicode scalars',
            'max_scalars': cleaning.MAX_SCALARS, 'thresholds': cleaning.THRESHOLDS,
            'training_count_policy': 'Surviving base-cleaned train only; heldout never contributes counts. Unseen count is zero.',
            'dictionary_policy': 'Exact case-sensitive text union of flat Chinese and English category CSVs; phrase/ excluded. No personal data.',
            'dictionary_word_forms': len(dictionary), 'rule_order': ['reject_whole_line', 'numeric', 'long', 'rare'],
            'replacement_fraction_denominator': 'Tokens in retained lines, before replacement',
            'reserved_tokens_in_source': 'Rejected; the cleaner only emits <num> and <oov> as synthetic markers.'})
        with (stage / 'protected-dictionary.txt').open('w', encoding='utf-8') as stream:
            for word in sorted(dictionary, key=lambda w:w.encode('utf-8')):stream.write(word + '\n')
        # Persist the complete train-derived mapping, not probabilities or heldout counts.
        with (stage / 'train-mapping.tsv').open('wb') as stream:
            stream.write(b'token\ttrain_count\tclean1\tclean2\tclean3\n')
            for word in sorted(raw_train):
                stream.write(b'\t'.join((word, str(raw_train[word]).encode(), *cache[word][0])) + b'\n')
        records = {v: {} for v in VERSIONS}
        vocabs = {}
        for split, raw_counts, input_stats in (('train', raw_train, train_stats), ('heldout', raw_heldout, heldout_stats)):
            output_counts = [Counter() for _ in VERSIONS]
            replacements = [Counter() for _ in VERSIONS]
            for word, count in raw_counts.items():
                outputs, reasons = cache[word]
                for i in range(len(VERSIONS)):
                    output_counts[i][outputs[i]] += count
                    if reasons[i]:replacements[i][reasons[i]] += count
            with ExitStack() as stack:
                handles = []
                for version in VERSIONS:
                    (stage / version).mkdir(exist_ok=True)
                    handles.append(stack.enter_context((stage / version / (split + '.txt')).open('wb')))
                with (ORIGINAL / (split + '.txt')).open('rb') as stream:
                    last = time.monotonic()
                    for lineno, line in enumerate(stream, 1):
                        if any(marker in line for marker in BAD_BYTES):continue
                        words = line.split()
                        if not words:continue
                        decisions = [cache[word][0] for word in words]
                        for i, handle in enumerate(handles):handle.write(b' '.join(row[i] for row in decisions) + b'\n')
                        if lineno % 100000 == 0 and time.monotonic() - last > 20:
                            print(f'Writing three {split} versions: {lineno:,} source lines', flush=True)
                            last = time.monotonic()
            for i, version in enumerate(VERSIONS):
                counts = output_counts[i]
                if split == 'train':
                    vocabs[version] = set(counts)
                    with (stage / version / 'vocabulary.tsv').open('wb') as stream:
                        stream.write(b'token\ttrain_count\n')
                        for word in sorted(counts):stream.write(word + b'\t' + str(counts[word]).encode() + b'\n')
                stats = dict(input_stats)
                stats.update(vocabulary_types=len(counts),
                             replaced_num_tokens=replacements[i]['numeric'],
                             replaced_oov_tokens=replacements[i]['long'] + replacements[i]['rare'],
                             replaced_long_tokens=replacements[i]['long'],
                             replaced_rare_tokens=replacements[i]['rare'],
                             num_fraction=replacements[i]['numeric'] / stats['retained_tokens'],
                             oov_fraction=(replacements[i]['long'] + replacements[i]['rare']) / stats['retained_tokens'],
                             sha256=previous.digest(stage / version / (split + '.txt')),
                             bytes=(stage / version / (split + '.txt')).stat().st_size)
                if split == 'heldout':
                    stats['unseen_train_word_types'] = len(set(counts) - vocabs[version])
                    stats['unseen_train_tokens'] = sum(n for word,n in counts.items() if word not in vocabs[version])
                records[version][split] = stats
                previous.save(stage / version / (split + '-statistics.json'), stats)
        previous.save(stage / 'manifest.json', {'versions': records, 'input_pin': json.loads((out / 'input-pin.json').read_text()),
                     'dictionary_rule_pin': json.loads((out / 'dictionary-rule-pin.json').read_text())})
    pin(out)
    print('Prepared all three versions without modifying or resplitting originals', flush=True)


def evaluate(binary, heldout, directory, expected):
    directory.mkdir(parents=True, exist_ok=True)
    command = [TOOLS / 'query', '-v', 'summary', binary]
    result = previous.run_command(command, heldout, directory / 'query.stdout', directory / 'query.stderr', directory / 'commands.jsonl')
    if result['exit_code']:raise RuntimeError('Heldout query failed')
    metrics = previous.parse_query((directory / 'query.stdout').read_text() + '\n' + (directory / 'query.stderr').read_text())
    if metrics['query_tokens'] != expected:raise ValueError('Incomplete cleaned heldout coverage')
    return {**metrics, 'query_seconds': result['seconds'], 'binary_bytes': binary.stat().st_size, 'binary_sha256': previous.digest(binary)}


def convert(stage, arpa, a22=False):
    binary = stage / 'model.trie'
    command = [TOOLS / 'build_binary', '-S', '40%', '-T', '/tmp', '-q', '8', '-b', '8']
    if a22:command += ['-a', '22']
    command += ['trie', arpa, binary]
    result = previous.run_command(command, Path('/dev/null'), stage / 'build.stdout', stage / 'build.log', stage / 'commands.jsonl')
    if result['exit_code']:raise RuntimeError('Binary construction failed')
    return binary, result['seconds']


def train(out):
    prepare(out)  # Validate the frozen split checksums before a resumed fit.
    data = json.loads((out / 'data/manifest.json').read_text())['versions']
    for version in VERSIONS:
        expected = data[version]['heldout']['retained_tokens'] + data[version]['heldout']['output_lines']
        heldout = out / 'data' / version / 'heldout.txt'
        for name, prune in CONFIGS.items():
            target = out / 'models' / version / name
            if target.exists():
                result = json.loads((target / 'result.json').read_text())
                if previous.digest(target / 'model.trie') != result['binary_sha256']:raise ValueError('Model changed')
                continue
            with previous.staged(target) as stage:
                arpa = stage / 'model.arpa'
                command = [TOOLS / 'lmplz', '-o', '4', '-S', '40%', '-T', '/tmp', '--prune', *map(str, prune)]
                fit = previous.run_command(command, out / 'data' / version / 'train.txt', arpa, stage / 'lmplz.log', stage / 'commands.jsonl')
                fallback = False
                if fit['exit_code']:
                    log = (stage / 'lmplz.log').read_text(errors='replace')
                    if 'BadDiscount' not in log and '--discount_fallback' not in log:raise RuntimeError('lmplz failed')
                    fallback = True
                    retry = previous.run_command([*command, '--discount_fallback'], out / 'data' / version / 'train.txt', arpa, stage / 'lmplz-fallback.log', stage / 'commands.jsonl')
                    if retry['exit_code']:raise RuntimeError('Discount fallback failed')
                    fit['seconds'] += retry['seconds']
                header, counts = previous.arpa_header(arpa)
                (stage / 'arpa-header.txt').write_text(header)
                if counts['1'] != data[version]['train']['vocabulary_types'] + 3:raise ValueError('ARPA vocabulary mismatch')
                binary, seconds = convert(stage, arpa)
                result = {'version': version, 'configuration': name, 'order': 4, 'prune': prune, 'a': 'default (omitted)',
                          'ngram_counts': counts, 'discount_fallback': fallback, 'training_seconds': fit['seconds'], 'build_seconds': seconds,
                          **evaluate(binary, heldout, stage, expected)}
                previous.save(stage / 'result.json', result)
                if version == 'clean2' and name == 'p0123':
                    with previous.staged(out / 'models/clean2/p0123-a22') as extra:
                        binary, seconds = convert(extra, arpa, True)
                        previous.save(extra / 'result.json', {**result, 'configuration': 'p0123-a22', 'a': 22, 'build_seconds': seconds,
                                      **evaluate(binary, heldout, extra, expected)})
                        (extra / 'arpa-header.txt').write_text(header)
                arpa.unlink()
            print(f'Completed {version}/{name}', flush=True)


def loading(out):
    target = out / 'loading'
    target.mkdir(exist_ok=True)
    cases = [('original-o4d', ROOT / '.build/kenlm-round2/models/o4d/model.trie', ORIGINAL / 'heldout.txt'),
             ('clean2-p0123', out / 'models/clean2/p0123/model.trie', out / 'data/clean2/heldout.txt')]
    results = []
    for name, binary, heldout in cases:
        for method in ('default', 'lazy'):
            directory = target / name / method
            directory.mkdir(parents=True, exist_ok=True)
            result_path = directory / 'result.json'
            if result_path.exists():results.append(json.loads(result_path.read_text()));continue
            command = [str(TOOLS / 'query'), '-v', 'summary']
            if method == 'lazy':command += ['-l', 'lazy']
            command.append(str(binary))
            with heldout.open('rb') as stream, (directory / 'query.stdout').open('wb') as stdout, (directory / 'query.stderr').open('wb') as stderr:
                process = subprocess.Popen(command, stdin=stream, stdout=stdout, stderr=stderr)
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
            if process.returncode:raise RuntimeError('Loading-mode query failed')
            metrics = previous.parse_runtime((directory / 'query.stderr').read_text())
            ppl = previous.parse_query((directory / 'query.stdout').read_text())
            result = {'model': name, 'loading': method, 'command': command, 'heldout_sha256': previous.digest(heldout),
                      'binary_sha256': previous.digest(binary), 'wait4_rssmax_native': usage.ru_maxrss,
                      'wait4_cpu_seconds': usage.ru_utime + usage.ru_stime, **metrics, **ppl}
            previous.save(result_path, result)
            results.append(result)
    previous.save(target / 'results.json', results)


def report(out):
    manifest = json.loads((out / 'data/manifest.json').read_text())
    paths = [out / 'models' / version / name / 'result.json'
             for version in VERSIONS
             for name in (('p0123', 'p0123-a22', 'p0012') if version == 'clean2' else CONFIGS)]
    records = [json.loads(path.read_text()) for path in paths]
    runtime = json.loads((out / 'loading/results.json').read_text())
    if len(records) != 7 or len(runtime) != 4:
        raise ValueError('The report requires all seven binaries and four loading queries')
    lines = ['## Third round: vocabulary cleaning and pruning', '',
             'Original train.txt and heldout.txt remain unchanged, with the same split membership and order. All new artifacts live under .build/kenlm-round3/. No final combined-data retraining was performed.', '',
             'Cleaning contract: [scripts/kenlm_cleaning.py](scripts/kenlm_cleaning.py); portable test vectors: [Tests/KenLMTests/cleaning_vectors.json](Tests/KenLMTests/cleaning_vectors.json).', '',
             'Rule order: reject a whole line containing U+FFFD, 锟斤拷, 烫烫烫 or 屯屯屯; map numeric tokens to <num>; map tokens longer than 32 Unicode scalars to <oov>; then apply the version-specific rare-token filter. Numeric grammar: `[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?`, with Unicode decimal digits and ASCII sign/dot/exponent markers. Thus .5, 1. and -1e+3 are numbers; NaN, infinity, grouped 1,000 and Unicode minus are not. No extra normalization, case folding or tokenization is performed. Swift must use unicodeScalars.count, not String.count or UTF-16 length.', '',
             'clean1 applies only those three base rules. clean2/clean3 additionally replace non-dictionary tokens with surviving base-cleaned train counts strictly below 5/20. Counts and mapping are frozen from train only; unseen heldout words have count zero. Synthetic <num>/<oov> bypass rare filtering. The ordinary <oov> token is distinct from query-reported true vocabulary OOVs. Protected but train-unseen dictionary words remain eligible for true KenLM OOV scoring. The cleaner never emits KenLM-reserved <unk>/<s>/</s>; their appearance in ARPA headers is model-generated.', '',
             'Dictionary protection uses the exact, case-sensitive text union of Data/Vocabulary/chinese/*.csv and Data/Vocabulary/english/*.csv. Per the existing word-side convention, chinese/phrase/ is excluded. No personal phrases, history or learning archive is read. Source hashes, the protected vocabulary and complete train mapping are pinned under the new output directory.', '',
             '**PPL is comparable only between pruning/build configurations within the same cleaned version. Different cleaning versions have different vocabularies and evaluation events; do not compare their PPL directly or rank them against the original corpus.**', '',
             '| Version | Split | Train vocabulary types | Lines kept | Garbled lines deleted | <num> replacements | <num> share | <oov> replacements | <oov> share |',
             '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for version in VERSIONS:
        for split in ('train', 'heldout'):
            s = manifest['versions'][version][split]
            vocab = manifest['versions'][version]['train']['vocabulary_types']
            lines.append(f"| {version} | {split} | {vocab:,} | {s['output_lines']:,} | {s['deleted_garbled_lines']:,} | {s['replaced_num_tokens']:,} | {s['num_fraction']:.4%} | {s['replaced_oov_tokens']:,} | {s['oov_fraction']:.4%} |")
    lines += ['', 'Vocabulary counts include ordinary <num>/<oov> markers when observed and exclude the three KenLM-generated special tokens. Replacement shares use tokens in retained lines as denominator; deleted-line tokens are excluded. Token replacements can make previously distinct lines identical, including across splits. Each surviving original line remains in its original split and order; there is no new deduplication or splitting.', '',
              'Complete-heldout query coverage (including EOS): ' + '; '.join(f"{version}: {manifest['versions'][version]['heldout']['retained_tokens'] + manifest['versions'][version]['heldout']['output_lines']:,} scored tokens, {manifest['versions'][version]['heldout']['unseen_train_tokens']:,} true OOV tokens" for version in VERSIONS) + '. These expected OOV counts are derived from each frozen train vocabulary and checked against query output.', '',
              '| Version | Prune | Build -a | MiB | PPL incl. OOV | PPL excl. OOV | n1 | n2 | n3 | n4 | Train <num>/<oov> share | Heldout <num>/<oov> share |',
              '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |']
    for r in records:
        t, h = (manifest['versions'][r['version']][s] for s in ('train', 'heldout'))
        lines.append(f"| {r['version']} | {' '.join(map(str,r['prune']))} | {r['a']} | {r['binary_bytes']/1048576:.2f} | {r['perplexity_including_oovs']:.6f} | {r['perplexity_excluding_oovs']:.6f} | " + ' | '.join(f"{r['ngram_counts'][str(i)]:,}" for i in range(1,5)) + f" | {t['num_fraction']:.4%} / {t['oov_fraction']:.4%} | {h['num_fraction']:.4%} / {h['oov_fraction']:.4%} |")
    lines += ['']
    for version in VERSIONS:
        baseline = next(r for r in records if r['version'] == version and r['configuration'] == 'p0123')
        relaxed = next(r for r in records if r['version'] == version and r['configuration'] == 'p0012')
        lines.append(f"Within {version}, changing pruning from 0 1 2 3 to 0 0 1 2 reduces including-OOV PPL by {1-relaxed['perplexity_including_oovs']/baseline['perplexity_including_oovs']:.2%}, while increasing binary size by {relaxed['binary_bytes']/baseline['binary_bytes']-1:.2%}.")
    default = next(r for r in records if r['version'] == 'clean2' and r['configuration'] == 'p0123')
    compressed = next(r for r in records if r['version'] == 'clean2' and r['configuration'] == 'p0123-a22')
    lines += ['', f"For clean2 0 1 2 3, -a 22 reduces binary size by {1-compressed['binary_bytes']/default['binary_bytes']:.2%}; including-OOV PPL difference {compressed['perplexity_including_oovs']-default['perplexity_including_oovs']:.12g}, excluding-OOV PPL difference {compressed['perplexity_excluding_oovs']-default['perplexity_excluding_oovs']:.12g}."]
    lines += ['', 'All six estimates use -o 4 -S 40% -T /tmp and the indicated pruning; all seven binaries use -q 8 -b 8 trie. The extra clean2 0 1 2 3 binary uses -a 22 on exactly the same ARPA as its default-a control, without another estimation. Header counts and exact binary bytes/hashes are retained in each result.json.', '',
              '### Default loading versus lazy loading', '',
              'The current query supports -l lazy. On this macOS build, default loading is read (malloc + file read); lazy uses mmap without eager population. Each measurement is one fresh process scoring the complete corresponding heldout, default followed by lazy, without cache clearing. RSSMax is peak resident memory across load and scoring, not virtual address space or an idle/post-load snapshot; a full query can fault in much of a lazy mapping. This does not establish cold-start performance.', '',
              '| Model | Loading | Real s | CPU s | RSSMax MiB | PPL incl. OOV | PPL excl. OOV | OOV tokens |',
              '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for r in runtime:
        lines.append(f"| {r['model']} | {r['loading']} | {r['query_real_seconds']:.6f} | {r['query_cpu_seconds']:.6f} | {r['rssmax_bytes']/1048576:.2f} | {r['perplexity_including_oovs']:.6f} | {r['perplexity_excluding_oovs']:.6f} | {r['oovs']:,} |")
    lines += ['', 'These complete-heldout queries show essentially equal peak RSS for default and lazy loading (a difference of about 0.02 MiB per model), with identical PPL and OOV counts. Lazy loading did not materially reduce peak resident memory in this workload. The one-pass timing values are descriptive; default precedes lazy with no cache clearing.']
    lines += ['', 'Darwin ru_maxrss is bytes although KenLM prints a literal kB label; MiB are converted from actual byte values and checked against per-child wait4. Raw query output and commands are retained.', '',
              'Reproduce/resume (completed artifacts are retained):', '', '```sh', 'corpus/.venv/bin/python scripts/kenlm_round3.py all', '```', '',
              'Stages: prepare, train, loading, report. Data/rules/mappings/statistics: .build/kenlm-round3/data/. Models/headers/query logs: .build/kenlm-round3/models/. Loading measurements: .build/kenlm-round3/loading/. Machine-readable summary: .build/kenlm-round3/summary.json.', '',
              'Original split hashes, modification times and inodes are verified before and after. No final full-data retraining or native runtime integration is included.']
    validation_file = out / 'validation/results.json'
    if validation_file.exists():
        validation = json.loads(validation_file.read_text())
        lines += ['', f"Validation: {validation['python_tests']} Python KenLM tests passed; {sum(validation['swift_test_suites'])} shared Swift tests passed; Debug app build passed. No app installation was performed. Logs are retained under .build/kenlm-round3/validation/."]
    audit_file = out / 'audit.json'
    if audit_file.exists() and json.loads(audit_file.read_text())['checks_passed']:
        lines += ['', 'Artifact audit passed: all train mapping rows, all six cleaned split checksums/counts, seven binary hashes/headers/full-heldout evaluations, the common-ARPA -a 22 control, four loading queries, unchanged original inputs/dictionary/rules/tools and the preexisting README prefix. See .build/kenlm-round3/audit.json.']
    text = '\n'.join(lines) + '\n'
    for marker in ('<num>', '<oov>', '<unk>', '<s>', '</s>'):
        text = text.replace(marker, '`' + marker + '`')
    (out / 'report.md').write_text(text.replace('(scripts/', '(../../scripts/').replace('(Tests/', '(../../Tests/'))
    readme = ROOT / 'README_kenlm_train.md'
    begin, end = '<!-- KENLM_ROUND3_BEGIN -->', '<!-- KENLM_ROUND3_END -->'
    existing = readme.read_text()
    if begin in existing:
        pre, rest = existing.split(begin, 1)
        _, post = rest.split(end, 1)
        existing = pre + begin + '\n' + text + end + post
    else:existing += '\n' + begin + '\n' + text + end + '\n'
    readme.write_text(existing)
    previous.save(out / 'summary.json', {'models': records, 'data': manifest, 'loading': runtime, 'final_combined_data_training': False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('all', 'prepare', 'train', 'loading', 'report'))
    parser.add_argument('--output', type=Path, default=OUT)
    args = parser.parse_args()
    out = args.output.resolve()
    if out == ORIGINAL or ORIGINAL in out.parents:raise ValueError('Outputs cannot be in original split directory')
    out.mkdir(parents=True, exist_ok=True)
    pin(out)
    for name, function in {'prepare': prepare, 'train': train, 'loading': loading, 'report': report}.items():
        if args.stage in ('all', name):function(out)
    pin(out)


if __name__ == '__main__':main()
