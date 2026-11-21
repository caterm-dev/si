#!/usr/bin/env python3
"""Validate and run SI's separate, offline recall and fixed-pool ranking suites."""

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'eval'
FILES = ('recall/test.jsonl', 'ranking/context.jsonl', 'ranking/context-free.jsonl')
LANGUAGES = ('zh-Hans', 'en')
HAN = re.compile(r'[\u3400-\u4dbf\u4e00-\u9fff]+')
SYLLABLE = re.compile(r'[a-z]+')
SPELLING = re.compile(r"[A-Za-züÜ:']+")
ESCAPE = re.compile(r"\\(?:u\{([0-9a-f]+)\}|([\\tnr0]))")


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def rows(path):
    with path.open(encoding='utf-8') as stream:
        return [json.loads(line) for line in stream]


def normalize(spelling):
    return spelling.lower().replace('ü', 'v').replace('u:', 'v').replace("'", '')


def encode(tokens, spelling):
    pieces = []
    for segment in tokens:
        if isinstance(segment, str):
            pieces.append(segment)
            continue
        chunk = ''
        for index, syllable in enumerate(segment):
            if index and (spelling == 'separated' or (spelling == 'boundary' and syllable[0] in 'aeo')):
                chunk += "'"
            chunk += syllable.replace('v', spelling) if spelling in ('ü', 'u:') else syllable
        pieces.append(chunk)
    return ''.join(pieces)


def ensure(condition, message):
    if not condition:
        raise ValueError(message)


def verify_recall(row):
    identity = row['id']
    reference, = row['references']
    ensure(row['languages'] in (['zh-Hans'], ['en'], list(LANGUAGES)), f'{identity}: languages')
    ensure(row['reference_language'] in ('zh-Hans', 'en', 'mixed'), f'{identity}: reference language')
    chunks = re.findall(r'[A-Za-z]+|[\u3400-\u4dbf\u4e00-\u9fff]+', reference)
    ensure(''.join(chunks) == reference.replace(' ', ''), f'{identity}: reference characters')
    for chunk, segment in zip(chunks, row['tokens'], strict=True):
        if isinstance(segment, str):
            ensure(chunk == segment and segment.isascii() and segment.isalpha(), f'{identity}: Latin segment')
        else:
            ensure(HAN.fullmatch(chunk) and len(chunk) == len(segment)
                   and all(SYLLABLE.fullmatch(s) for s in segment), f'{identity}: syllable alignment')
    han_count = sum(isinstance(part, list) for part in row['tokens'])
    language = 'zh-Hans' if han_count == len(chunks) else 'mixed' if han_count else 'en'
    ensure(language == row['reference_language'], f'{identity}: language alignment')
    ensure(row['spelling'] in ('continuous', 'boundary', 'separated', 'ü', 'u:')
           and encode(row['tokens'], row['spelling']) == row['input'], f'{identity}: typed spelling')
    ensure(isinstance(row['context'], str), f'{identity}: context')


def verify_ranking(row, contextual):
    identity = row['id']
    candidates, references = row['candidates'], row['references']
    ensure(2 <= len(candidates) <= 8 and len(set(candidates)) == len(candidates), f'{identity}: pool')
    ensure(0 < len(references) < len(candidates) and len(set(references)) == len(references)
           and set(references) <= set(candidates), f'{identity}: references')
    for candidate, units in zip(candidates, row['syllables'], strict=True):
        ensure(HAN.fullmatch(candidate) and len(candidate) == len(units)
               and all(SYLLABLE.fullmatch(s) for s in units)
               and ''.join(units) == normalize(row['input']), f'{identity}: syllable alignment')
    ensure(isinstance(row['context'], str) and bool(row['context']) == contextual, f'{identity}: context')
    if contextual:
        ensure(row['pair'] and len(references) == 1 and len(candidates) == 2
               and not any(text in row['context'] for text in candidates), f'{identity}: context contrast')
    else:
        ensure('pair' not in row, f'{identity}: unexpected pair')


def load_data():
    manifest = json.loads((DATA / 'conversion-manifest.json').read_text())
    suites = {}
    identities = set()
    seen_examples = {}
    spelling_suites = {}
    pairs = defaultdict(list)
    for name in FILES:
        path = DATA / name
        suite = rows(path)
        sources = set()
        for row in suite:
            identity = row['id']
            ensure(identity not in identities and SPELLING.fullmatch(row['input'])
                   and row['category'], f'{identity}: duplicate ID or malformed query')
            identities.add(identity)
            source = normalize(row['input'])
            ensure(spelling_suites.setdefault(source, name) == name,
                   f'{identity}: spelling occurs in another suite')
            ensure(source not in sources or name == FILES[1], f'{identity}: duplicate spelling')
            sources.add(source)
            for ref in row['references']:
                key = (source, ref)
                ensure(key not in seen_examples, f'{identity}: duplicate spelling/reference with {seen_examples.get(key)}')
                seen_examples[key] = identity
            if name == FILES[0]:
                verify_recall(row)
            else:
                contextual = name == FILES[1]
                verify_ranking(row, contextual)
                if contextual:
                    pairs[row['pair']].append(row)
        if name == FILES[1]:
            ensure(len(sources) == len(pairs), 'Contextual groups must have distinct spellings')
        declared = manifest['files'][name]
        categories = {key: value for key, value in Counter(row['category'] for row in suite).items()}
        ensure(declared == {'rows': len(suite), 'categories': categories, 'sha256': sha256(path)},
               f'{name}: manifest mismatch')
        suites[name] = suite
    for identity, pair in pairs.items():
        ensure(len(pair) == 2, f'{identity}: missing contrast')
        first, second = pair
        ensure(first['input'] == second['input'] and first['candidates'] == second['candidates']
               and first['category'] == second['category'] and first['syllables'] == second['syllables']
               and first['references'] != second['references'] and first['context'] != second['context'],
               f'{identity}: contrast must hold the input and ordered pool fixed and reverse the label')
    return suites, manifest


def verify_lexicon_readings(suites):
    expected = defaultdict(set)
    for row in suites[FILES[0]]:
        text, = row['references']
        for chunk, units in zip(re.findall(r'[A-Za-z]+|[\u3400-\u4dbf\u4e00-\u9fff]+', text),
                                row['tokens'], strict=True):
            if isinstance(units, list):
                for character, unit in zip(chunk, units, strict=True):
                    expected[character].add(unit)
    for name in FILES[1:]:
        for row in suites[name]:
            for candidate, units in zip(row['candidates'], row['syllables'], strict=True):
                for character, unit in zip(candidate, units, strict=True):
                    expected[character].add(unit)
    for file in sorted((ROOT / 'Data/Chinese').glob('*.csv')):
        with file.open(encoding='utf-8', newline='') as stream:
            for entry in csv.DictReader(stream):
                character = entry['text']
                if character in expected:
                    unit = normalize(entry['reading'])
                    unit = {'lue': 'lve', 'nue': 'nve'}.get(unit, unit)
                    expected[character].discard(unit)
    missing = {character: sorted(units) for character, units in expected.items() if units}
    ensure(not missing, f'Syllables missing from maintained single-character readings: {missing}')


def verify_maintained_split(suites):
    evaluated = {(normalize(row['input']), row['context'], reference): row['id']
                 for suite in suites.values() for row in suite for reference in row['references']}
    fixed_lambdarank = DATA / 'lambdarank'
    for name in ('train.jsonl', 'validation.jsonl'):
        for row in rows(fixed_lambdarank / name):
            for target in row['references']:
                matched = evaluated.get((normalize(row['input']), row['context'], target))
                ensure(matched is None, f'{matched}: duplicate query and target in LambdaRank {name}')
    pinyin_data = ROOT / 'llm/pinyin_to_text/data'
    for path in sorted(pinyin_data.glob('*/train/*.csv')):
        with path.open(encoding='utf-8', newline='') as stream:
            for row in csv.DictReader(stream):
                matched = evaluated.get((normalize(row['input']), row['context'], row['target']))
                ensure(matched is None, f'{matched}: duplicate query and target in {path.relative_to(ROOT)}')


def external(command, payload):
    return subprocess.run(command, input=payload, encoding='utf-8', capture_output=True, check=True).stdout


def unescape(text):
    controls = {'\\': '\\', 't': '\t', 'n': '\n', 'r': '\r', '0': '\0'}
    return ESCAPE.sub(lambda m: chr(int(m[1], 16)) if m[1] else controls[m[2]], text)


def parse_engine(output):
    if not output:
        return []
    line = output.split('\n')
    ensure(line[-2:] == ['', ''], 'Incomplete engine result')
    result = []
    candidates = []
    for raw in line[:-1]:
        if raw == '':
            result.append(candidates)
            candidates = []
            continue
        language, consumed, kind, score, text = raw.split('\t', 4)
        candidates.append({'language': language, 'consumed_bytes': int(consumed),
                           'kind': kind, 'score_bits': float(score) if score else None,
                           'text': unescape(text)})
    return result


def recall_eval(suite, cli, lexicon, grams):
    groups = defaultdict(list)
    for row in suite:
        groups[(','.join(row['languages']), row['context'])].append(row)
    results = {}
    for (languages, context), group in groups.items():
        command = [cli, 'candidates', lexicon, '--grams', grams, '--languages', languages,
                   '--search', 'full', '--pinyin-correction', 'off', '--preceding', context]
        pools = parse_engine(external(command, ''.join(row['input'] + '\n' for row in group)))
        for row, candidates in zip(group, pools, strict=True):
            identity, source = row['id'], row['input']
            consumed = len(source.encode('utf-8'))
            ensure(any(c['kind'] == 'literal' and c['text'] == source
                       and c['consumed_bytes'] == consumed for c in candidates),
                   f'{identity}: literal fallback missing')
            eligible = [c for c in candidates if c['kind'] == 'exact' and c['consumed_bytes'] == consumed]
            rank = next((index for index, candidate in enumerate(eligible, 1)
                         if candidate['language'] == row['reference_language']
                         and candidate['text'] in row['references']), None)
            results[identity] = {'id': identity, 'input': source, 'category': row['category'],
                                 'references': row['references'], 'reference_language': row['reference_language'],
                                 'context': row['context'], 'rank': rank,
                                 'eligible_count': len(eligible), 'candidates': candidates}
    return [results[row['id']] for row in suite]


def ranking_eval(suite, cli, model, use_context):
    request = ''.join(json.dumps({'context': row['context'] if use_context else '',
                                 'candidates': row['candidates']}, ensure_ascii=False) + '\n' for row in suite)
    predictions = (json.loads(line) for line in external([cli, 'rank', model], request).splitlines())
    results = []
    for row, prediction in zip(suite, predictions, strict=True):
        order, scores = prediction['order'], prediction['scores']
        size = len(row['candidates'])
        abstained = prediction['abstained']
        ensure(sorted(order) == list(range(size)) and len(scores) == size
               and (all(value is None for value in scores) if abstained
                    else all(isinstance(value, (int, float)) and math.isfinite(value) for value in scores)),
               f"{row['id']}: malformed ranking result")
        rank = next(i for i, index in enumerate(order, 1) if row['candidates'][index] in row['references'])
        results.append({'id': row['id'], 'category': row['category'], 'rank': None if abstained else rank,
                        'pool_origin': row['pool_origin'],
                        'order': order, 'scores': scores, 'abstained': abstained})
    return results


def summarize(results):
    ranks = [row['rank'] for row in results]
    return {'queries': len(ranks), 'top1': ranks.count(1),
            'top3': sum(rank is not None and rank <= 3 for rank in ranks),
            'top5': sum(rank is not None and rank <= 5 for rank in ranks),
            'mrr': sum(1 / rank for rank in ranks if rank is not None) / len(ranks)}


def recall_metrics(results):
    ranks = [row['rank'] for row in results]
    return {'queries': len(ranks), 'full_pool_hits': sum(rank is not None for rank in ranks),
            'first_9_hits': sum(rank is not None and rank <= 9 for rank in ranks),
            'first_27_hits': sum(rank is not None and rank <= 27 for rank in ranks),
            'first_32_hits': sum(rank is not None and rank <= 32 for rank in ranks)}


def breakdown(suite, field, metrics):
    groups = defaultdict(list)
    for row in suite:
        groups[row[field]].append(row)
    return {label: metrics(group) for label, group in sorted(groups.items())}


def paired_top1(suite, results):
    successes = defaultdict(list)
    for query, result in zip(suite, results, strict=True):
        successes[query['pair']].append(result['rank'] == 1)
    return {'pairs': len(successes), 'both_top1': sum(all(group) for group in successes.values())}


def evaluate_recall(args, suites, manifest):
    results = recall_eval(suites[FILES[0]], args.cli, args.lexicon, args.grams)
    return {'protocol': 'Rust full search, correction off, empty user profile; language-matched whole exact candidates',
            'dataset': manifest['files'][FILES[0]]['sha256'],
            'cli_sha256': sha256(args.cli), 'lexicon_sha256': sha256(args.lexicon),
            'grams_sha256': sha256(args.grams),
            'overall': recall_metrics(results),
            'by_language': breakdown(results, 'reference_language', recall_metrics),
            'by_category': breakdown(results, 'category', recall_metrics),
            'results': results}


def evaluate_ranking(args, suites, manifest):
    context = suites[FILES[1]]
    free = suites[FILES[2]]
    conditioned = ranking_eval(context, args.cli, args.model, True)
    ablated = ranking_eval(context, args.cli, args.model, False)
    standalone = ranking_eval(free, args.cli, args.model, False)
    return {'protocol': 'Isolated character LM on ordered frozen candidate pools; abstentions count as misses',
            'datasets': {name: manifest['files'][name]['sha256'] for name in FILES[1:]},
            'cli_sha256': sha256(args.cli), 'model_sha256': sha256(args.model / 'model.json'),
            'weights_sha256': sha256(args.model / 'weights.f32'),
            'contextual': {'with_context': summarize(conditioned), 'without_context': summarize(ablated),
                           'paired_with_context': paired_top1(context, conditioned),
                           'paired_without_context': paired_top1(context, ablated),
                           'with_context_by_category': breakdown(conditioned, 'category', summarize),
                           'without_context_by_category': breakdown(ablated, 'category', summarize)},
            'context_free': {'overall': summarize(standalone),
                             'by_category': breakdown(standalone, 'category', summarize),
                             'by_pool_origin': breakdown(standalone, 'pool_origin', summarize)},
            'results': {'conditioned': conditioned, 'ablated': ablated, 'context_free': standalone}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check')
    recall = commands.add_parser('recall')
    recall.add_argument('--cli', type=Path, default=ROOT / 'target/release/si-cli')
    recall.add_argument('--lexicon', type=Path, default=ROOT / '.build/si-data/main.silex')
    recall.add_argument('--grams', type=Path, default=ROOT / '.build/si-data/words.sigram')
    recall.add_argument('--output', type=Path, required=True)
    ranking = commands.add_parser('ranking')
    ranking.add_argument('--cli', type=Path, default=ROOT / 'target/release/si-neural')
    ranking.add_argument('--model', type=Path, required=True)
    ranking.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    suites, manifest = load_data()
    if args.command == 'check':
        verify_lexicon_readings(suites)
        verify_maintained_split(suites)
        print(json.dumps({name: len(suite) for name, suite in suites.items()}))
        return
    if args.output.exists():
        parser.error(f'output already exists: {args.output}')
    evaluate = evaluate_recall if args.command == 'recall' else evaluate_ranking
    report = evaluate(args, suites, manifest)
    with args.output.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({key: report[key] for key in ('overall', 'contextual', 'context_free') if key in report}))


if __name__ == '__main__':
    main()
