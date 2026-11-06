#!/usr/bin/env python3
"""Explicit final clean2 fit on train then heldout; no independent evaluation."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import statistics
import time
import unicodedata

import kenlm_cleaning as cleaning
import kenlm_round3 as round3

previous = round3.previous
ROOT = previous.ROOT
OUT = ROOT / '.build/kenlm-final'
TOOLS = previous.TOOLS
INPUTS = tuple(round3.ORIGINAL / (name + '.txt') for name in ('train', 'heldout'))
FIXTURE = ROOT / 'Tests/KenLMTests/final_sanity_sentences.json'
TOKENIZER_DICTIONARY = ROOT / 'corpus/chinese/dictionaries/generated/unigram-words-v2/frequencies.csv'
CONFIGS = {'final': [0, 1, 2, 3], 'final_large': [0, 0, 1, 2]}


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def canonical_sha(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def file_record(path):
    stat = path.stat()
    return {'path': str(path.relative_to(ROOT)), 'sha256': previous.digest(path),
            'bytes': stat.st_size, 'mtime_ns': stat.st_mtime_ns, 'inode': stat.st_ino}


def pin(out, verify_old_models=False):
    previous.pin_inputs(out)
    paths = round3.dictionary_sources() + [ROOT / 'scripts/kenlm_cleaning.py',
        ROOT / 'Tests/KenLMTests/cleaning_vectors.json', FIXTURE, TOKENIZER_DICTIONARY,
        ROOT / 'corpus/tokenize_unigram.py', ROOT / 'corpus/kenlm/source.lock.json',
        round3.ORIGINAL / 'manifest.json',
        ROOT / 'corpus/chinese/generated/kenlm-words-v2/manifest.json',
        ROOT / 'corpus/chinese/kenlm-words-v2.snapshot.json']
    paths += [TOOLS / name for name in ('lmplz', 'build_binary', 'query')]
    paths += [ROOT / 'mac/SI/Core/Resources' / language / 'dictionary-manifest.json' for language in ('Chinese', 'English')]
    state = {str(p.relative_to(ROOT)): file_record(p) for p in paths}
    target = out / 'source-pin.json'
    if target.exists() and json.loads(target.read_text()) != state:
        raise ValueError('An input, cleaning contract, dictionary, fixture or tool changed')
    if not target.exists():previous.save(target, state)
    old_pin = out / 'train-only-models-pin.json'
    roots = [previous.OLD / 'models', ROOT / '.build/kenlm-round2', ROOT / '.build/kenlm-round3']
    old_paths = sorted(p for root in roots for p in root.rglob('model.trie'))
    if old_pin.exists():
        old = json.loads(old_pin.read_text())
        if set(old) != {str(p.relative_to(ROOT)) for p in old_paths}:raise ValueError('Train-only model set changed')
        for p in old_paths:
            s = p.stat();expected = old[str(p.relative_to(ROOT))]
            if (s.st_size, s.st_mtime_ns, s.st_ino) != (expected['bytes'], expected['mtime_ns'], expected['inode']):
                raise ValueError('A train-only model changed')
            if verify_old_models and previous.digest(p) != expected['sha256']:raise ValueError('Train-only model checksum changed')
    else:previous.save(old_pin, {str(p.relative_to(ROOT)): file_record(p) for p in old_paths})


def provenance(out):
    split = json.loads((round3.ORIGINAL / 'manifest.json').read_text())
    upstream_path = ROOT / 'corpus/chinese/generated/kenlm-words-v2/manifest.json'
    upstream = json.loads(upstream_path.read_text())
    snapshot = json.loads((ROOT / 'corpus/chinese/kenlm-words-v2.snapshot.json').read_text())
    if split['input']['sha256'] != upstream['combined']['sha256']:
        raise ValueError('Split lineage does not match the v2 corpus')
    if previous.digest(upstream_path) != snapshot['manifest_sha256']:
        raise ValueError('V2 manifest does not match retained snapshot')
    result = {'pipeline': 'kenlm-words-v2', 'split_pipeline': 'kenlm-selection-v1',
              'legacy_non_han_boundary_4_to_96_filter_applied': False,
              'upstream_combined_sha256': upstream['combined']['sha256'],
              'upstream_manifest_sha256': previous.digest(upstream_path),
              'scope_evidence': upstream['scope'], 'extraction_contract': 'complete-raw-text-lines-v1',
              'tokenization': 'NFKC, nonprinting removal, word-side unigram Viterbi; punctuation retained; English lowercase; sentence boundaries 。！？.!?; >100-token sentences dropped.',
              'existing_deduplication': {'unique_lines': split['unique_lines'], 'duplicate_lines_removed': split['duplicate_lines_removed'], 'seed': split['seed'], 'block_lines': split['block_lines']},
              'evidence_files': ['corpus/chinese/generated/kenlm-selection-v1/data/manifest.json',
                                 'corpus/chinese/generated/kenlm-words-v2/manifest.json',
                                 'corpus/chinese/kenlm-words-v2.snapshot.json',
                                 'corpus/prepare_raw_text.py', 'corpus/prepare_kenlm_raw.py', 'corpus/tokenize_unigram.py',
                                 'corpus/prepare.py', 'corpus/clean/chinese.py'],
              'new_deduplication_or_splitting': False}
    result['recorded_tokenizer_identities']=[{'source':s['id'],**s['identity']} for s in upstream['sources']]
    result['evidence_code_sha256']={path:previous.digest(ROOT/path) for path in result['evidence_files'] if path.endswith('.py')}
    result['tokenizer_frequency_reference']={
        'path':upstream['dictionary']['provenance']['frequency_reference'],
        'sha256':upstream['dictionary']['provenance']['frequency_reference_sha256'],
        'role':'Earlier HanLP word-frequency observations reused only as segmentation weights, not as training text.'}
    verified_path = out / 'upstream-verification.json'
    if verified_path.exists():
        verified = json.loads(verified_path.read_text())
        if verified['sha256'] != upstream['combined']['sha256']:raise ValueError('Actual upstream bytes do not match lineage')
        result['actual_upstream_file_verified'] = verified
    previous.save(out / 'corpus-provenance.json', result)
    return result


def merge_and_count(inputs, destination):
    counts = Counter();parts = [];combined = hashlib.sha256()
    with destination.open('wb') as merged:
        for path in inputs:
            stats = Counter();source_sha = hashlib.sha256();last = time.monotonic()
            with path.open('rb') as stream:
                for line in stream:
                    if not line.endswith(b'\n'):raise ValueError('A source line lacks its original LF')
                    merged.write(line);source_sha.update(line);combined.update(line)
                    stats['input_lines'] += 1
                    words = line.split();stats['input_tokens'] += len(words)
                    if any(marker in line for marker in round3.BAD_BYTES):
                        stats['deleted_garbled_lines'] += 1;stats['deleted_garbled_tokens'] += len(words)
                    elif not words:stats['empty_lines'] += 1
                    else:
                        counts.update(words);stats['output_lines'] += 1;stats['retained_tokens'] += len(words)
                    if stats['input_lines'] % 100000 == 0 and time.monotonic()-last > 20:
                        print(f'Merge/count {path.name}: {stats["input_lines"]:,} lines', flush=True);last=time.monotonic()
            for key in ('deleted_garbled_lines','deleted_garbled_tokens','empty_lines'):stats.setdefault(key,0)
            parts.append({'source': str(path), 'sha256': source_sha.hexdigest(), **dict(stats)})
    return counts, parts, combined.hexdigest()


def make_mapping(raw_counts, dictionary):
    base_counts = Counter()
    for word, count in raw_counts.items():base_counts[cleaning.base_token(word.decode('utf-8'))[0]] += count
    mapper = cleaning.FrozenMapper(base_counts, dictionary, 5)
    cache = {};output_counts = Counter();replacements = Counter()
    for word,count in raw_counts.items():
        mapped,reason = mapper.token(word);cache[word] = (mapped,reason)
        output_counts[mapped] += count
        if reason:replacements[reason] += count
    return cache,output_counts,replacements


def prepare(out):
    target = out / 'data'
    if target.exists():
        if not (out / 'full.clean2.txt').exists() and (target / 'full.clean2.txt').exists():
            (target / 'full.clean2.txt').rename(out / 'full.clean2.txt')
        record = json.loads((target / 'manifest.json').read_text())
        if previous.digest(out / 'full.clean2.txt') != record['cleaned']['sha256']:raise ValueError('Final cleaned data changed')
        return record
    dictionary = round3.dictionary_words()
    with previous.staged(target) as stage:
        raw_counts,parts,raw_sha = merge_and_count(INPUTS, stage / 'full.raw.txt')
        source_manifest = json.loads((round3.ORIGINAL / 'manifest.json').read_text())['splits']
        for name,p in zip(('train','heldout'),parts):
            for key in ('sha256','input_lines','input_tokens'):
                expected_key = {'input_lines':'lines','input_tokens':'tokens'}.get(key,key)
                if p[key] != source_manifest[name][expected_key]:raise ValueError('Merged source coverage mismatch')
        cache,output_counts,replacements = make_mapping(raw_counts,dictionary)
        with (stage / 'full-mapping.tsv').open('wb') as stream:
            stream.write(b'token\tfull_surviving_count\tclean2\treason\n')
            for word in sorted(raw_counts):
                mapped,reason=cache[word]
                stream.write(b'\t'.join((word,str(raw_counts[word]).encode(),mapped,(reason or 'unchanged').encode()))+b'\n')
        with (stage / 'vocabulary.tsv').open('wb') as stream:
            stream.write(b'token\tfull_count\n')
            for word in sorted(output_counts):stream.write(word+b'\t'+str(output_counts[word]).encode()+b'\n')
        with (stage / 'protected-dictionary.txt').open('w',encoding='utf-8') as stream:
            for word in sorted(dictionary,key=lambda w:w.encode()):stream.write(word+'\n')
        last=time.monotonic();lines=tokens=0
        with (stage / 'full.raw.txt').open('rb') as source,(stage / 'full.clean2.txt').open('wb') as output:
            for index,line in enumerate(source,1):
                if any(marker in line for marker in round3.BAD_BYTES):continue
                words=line.split()
                if not words:continue
                output.write(b' '.join(cache[word][0] for word in words)+b'\n');lines+=1;tokens+=len(words)
                if index%100000==0 and time.monotonic()-last>20:
                    print(f'Writing final clean2: {index:,} merged source lines',flush=True);last=time.monotonic()
        if tokens!=sum(output_counts.values()):raise ValueError('Final token count mismatch')
        cleaned={'file':'full.clean2.txt','sha256':previous.digest(stage/'full.clean2.txt'),
                 'bytes':(stage/'full.clean2.txt').stat().st_size,'lines':lines,'tokens':tokens,
                 'vocabulary_types':len(output_counts),'arpa_vocabulary_including_specials':len(output_counts)+3,
                 'replaced_num_tokens':replacements['numeric'],
                 'replaced_oov_tokens':replacements['long']+replacements['rare'],
                 'num_token_count':output_counts[b'<num>'],'oov_token_count':output_counts[b'<oov>'],
                 'num_fraction':output_counts[b'<num>']/tokens,'oov_fraction':output_counts[b'<oov>']/tokens,
                 'replaced_long_tokens':replacements['long'],'replaced_rare_tokens':replacements['rare'],
                 'deleted_garbled_lines':sum(p['deleted_garbled_lines'] for p in parts),
                 'deleted_garbled_tokens':sum(p['deleted_garbled_tokens'] for p in parts)}
        record={'created_at':utc_now(),'source_order':['train','heldout'],'sources':parts,
                'merged_raw':{'file':'data/full.raw.txt','sha256':raw_sha,'bytes':(stage/'full.raw.txt').stat().st_size},
                'cleaned':cleaned,'mapping':{'file':'data/full-mapping.tsv','sha256':previous.digest(stage/'full-mapping.tsv'),'rows':len(raw_counts)},
                'vocabulary':{'file':'data/vocabulary.tsv','sha256':previous.digest(stage/'vocabulary.tsv')},
                'dictionary':{'file':'data/protected-dictionary.txt','sha256':previous.digest(stage/'protected-dictionary.txt'),'word_forms':len(dictionary)},
                'count_population':'Surviving base-cleaned train + heldout; full frequencies recalculated before rare filtering.',
                'new_deduplication':False,'new_splitting':False}
        previous.save(stage/'manifest.json',record)
    (target/'full.clean2.txt').rename(out/'full.clean2.txt')
    print('Prepared final full clean2 corpus',flush=True)
    return record


def arpa_vocabulary(path):
    words=set()
    with path.open() as stream:
        for line in stream:
            if line.startswith('\\1-grams:'):break
        for line in stream:
            if line.startswith('\\2-grams:'):break
            if line.strip():words.add(line.split()[1])
    if not {'<num>','<oov>'}.issubset(words):raise ValueError('Synthetic markers missing from ARPA vocabulary')
    return len(words)


def train(out):
    data=prepare(out)
    for name,prune in CONFIGS.items():
        result_path=out/(name+'.result.json');binary=out/(name+'.bin');arpa=out/(name+'.arpa')
        if result_path.exists():
            result=json.loads(result_path.read_text())
            if previous.digest(binary)!=result['binary_sha256'] or previous.digest(arpa)!=result['arpa_sha256']:
                raise ValueError('Completed final model changed')
            continue
        if binary.exists():raise FileExistsError('Unfinished binary exists; preserve it before retrying')
        journal=out/'commands.jsonl';started=utc_now()
        command=[TOOLS/'lmplz','-o','4','--prune',*map(str,prune),'-S','40%','-T','/tmp']
        fit=previous.run_command(command,out/'full.clean2.txt',arpa,out/(name+'.lmplz.log'),journal)
        fallback=False
        if fit['exit_code']:
            log=(out/(name+'.lmplz.log')).read_text(errors='replace')
            if 'BadDiscount' not in log and '--discount_fallback' not in log:raise RuntimeError('lmplz failed')
            fallback=True;print('Discount estimation failed; retrying '+name+' with --discount_fallback',flush=True)
            retry=previous.run_command([*command,'--discount_fallback'],out/'full.clean2.txt',arpa,out/(name+'.lmplz-fallback.log'),journal)
            if retry['exit_code']:raise RuntimeError('Discount fallback failed')
            fit['seconds']+=retry['seconds']
        header,counts=previous.arpa_header(arpa);(out/(name+'.arpa-header.txt')).write_text(header)
        vocab=arpa_vocabulary(arpa)
        if vocab!=data['cleaned']['arpa_vocabulary_including_specials'] or counts['1']!=vocab:
            raise ValueError('Final vocabulary mismatch')
        build_command=[TOOLS/'build_binary','-a','22','-q','8','-b','8','trie',arpa,binary]
        build=previous.run_command(build_command,Path('/dev/null'),out/(name+'.build.stdout'),out/(name+'.build.log'),journal)
        if build['exit_code']:raise RuntimeError('Final binary construction failed')
        result={'name':name,'prune':prune,'order':4,'a':22,'probability_bits':8,'backoff_bits':8,
                'build_started_at':started,'build_completed_at':utc_now(),'training_seconds':fit['seconds'],
                'binary_build_seconds':build['seconds'],'discount_fallback':fallback,
                'ngram_counts':counts,'vocabulary_including_specials':vocab,'markers_present':['<num>','<oov>'],
                'binary_file':binary.name,'binary_bytes':binary.stat().st_size,'binary_sha256':previous.digest(binary),
                'arpa_file':arpa.name,'arpa_bytes':arpa.stat().st_size,'arpa_sha256':previous.digest(arpa),
                'training_command':[str(x) for x in command]+(['--discount_fallback'] if fallback else []),
                'binary_command':[str(x) for x in build_command],'intended_use':'deployment artifact' if name=='final' else 'offline comparison only; do not bundle in app'}
        previous.save(result_path,result);print('Completed '+name,flush=True)


def reversed_pair(tokens):
    if len(tokens)<5 or tokens[-1] not in ('。','.','!','！','?','？'):raise ValueError('Sanity sentence is too short or lacks final punctuation')
    return list(reversed(tokens[:-1]))+[tokens[-1]]


def parse_sentence_scores(text,expected):
    rows=[{'log10_probability':float(m[0]),'oovs':int(m[1])}
          for m in re.findall(r'^Total: ([0-9.eE+\-]+) OOV: (\d+)\s*$',text,re.M)]
    if len(rows)!=expected:raise ValueError('Incomplete sentence score output')
    return rows


def sanity(out):
    target=out/'sanity';target.mkdir(exist_ok=True)
    if (target/'results.json').exists():return json.loads((target/'results.json').read_text())
    from tokenize_unigram import load_dictionary,normalize_line,tokenize_sentence
    tokenizer=load_dictionary(TOKENIZER_DICTIONARY)
    needed=set();fixture=json.loads(FIXTURE.read_text());pairs=[]
    for text in fixture['good_sentences']:
        words=tokenize_sentence(normalize_line(text),tokenizer)
        if words is None:raise ValueError('Sanity sentence exceeds tokenizer limit')
        pairs.append({'good_sentence':text,'source_tokens':words});needed.update(words)
    raw_frequencies={}
    with (out/'data/full-mapping.tsv').open() as stream:
        next(stream)
        for line in stream:
            word,frequency,_,_=line.rstrip('\n').split('\t')
            if word in needed:raw_frequencies[word]=int(frequency)
    dictionary=round3.dictionary_words();all_lines=[]
    for p in pairs:
        good=[cleaning.map_token(w,raw_frequencies,dictionary,5)[0] for w in p['source_tokens']]
        bad=reversed_pair(good)
        p.update(good_tokens=good,bad_tokens=bad,bad_sentence=''.join(bad),scored_tokens_including_eos=len(good)+1)
        all_lines.extend((' '.join(good),' '.join(bad)))
    (target/'pairs.txt').write_text('\n'.join(all_lines)+'\n')
    (target/'markers.txt').write_text('<num> <oov>\n')
    previous.save(target/'pairs.json',{'fixture_sha256':previous.digest(FIXTURE),'tokenizer_dictionary_sha256':previous.digest(TOKENIZER_DICTIONARY),'pairs':pairs})
    results={}
    for name in CONFIGS:
        for loading in ('default','lazy') if name=='final' else ('default',):
            label=name+'-'+loading;command=[TOOLS/'query','-v','sentence','-v','summary']
            if loading=='lazy':command+=['-l','lazy']
            command.append(out/(name+'.bin'))
            run=previous.run_command(command,target/'pairs.txt',target/(label+'.stdout'),target/(label+'.stderr'),out/'commands.jsonl')
            if run['exit_code']:raise RuntimeError('Sanity query failed')
            text=(target/(label+'.stdout')).read_text();scores=parse_sentence_scores(text,40)
            pair_results=[]
            for i,p in enumerate(pairs):
                good,bad=scores[2*i:2*i+2]
                if good['oovs']!=bad['oovs']:raise ValueError('Pair vocabulary differs')
                margin=(good['log10_probability']-bad['log10_probability'])/p['scored_tokens_including_eos']
                pair_results.append({'pair':i+1,'good_log10':good['log10_probability'],'bad_log10':bad['log10_probability'],
                                     'oovs_per_side':good['oovs'],'margin_log10_per_token':margin,'good_wins':margin>0})
            wins=sum(p['good_wins'] for p in pair_results);median=statistics.median(p['margin_log10_per_token'] for p in pair_results)
            limits=fixture['acceptance_before_scoring'];passed=wins==limits['required_pair_wins'] and median>=limits['minimum_median_log10_margin_per_token_including_eos']
            results[label]={'wins':wins,'pairs':20,'median_margin_log10_per_token':median,'passed':passed,
                            'mean_good_log10_per_token':statistics.mean(scores[2*i]['log10_probability']/p['scored_tokens_including_eos'] for i,p in enumerate(pairs)),
                            'mean_bad_log10_per_token':statistics.mean(scores[2*i+1]['log10_probability']/p['scored_tokens_including_eos'] for i,p in enumerate(pairs)),
                            'per_pair':pair_results,'runtime':previous.parse_runtime((target/(label+'.stderr')).read_text())}
        command=[TOOLS/'query','-v','word',out/(name+'.bin')]
        run=previous.run_command(command,target/'markers.txt',target/(name+'-markers.stdout'),target/(name+'-markers.stderr'),out/'commands.jsonl')
        if run['exit_code']:raise RuntimeError('Marker query failed')
        text=(target/(name+'-markers.stdout')).read_text()
        for marker in ('<num>','<oov>'):
            match=re.search(re.escape(marker)+r'=(\d+) ',text)
            if not match or int(match[1])==0:raise ValueError('Marker is not an ordinary known vocabulary token')
    if results['final-default']['per_pair']!=results['final-lazy']['per_pair']:raise ValueError('Lazy/default scores differ')
    previous.save(target/'results.json',results)
    return results


def comparison(out):
    rows=[]
    for name,baseline in (('final','p0123-a22'),('final_large','p0012')):
        full=json.loads((out/(name+'.result.json')).read_text())
        old=json.loads((ROOT/'.build/kenlm-round3/models/clean2'/baseline/'result.json').read_text())
        rows.append({'model':name,'baseline':'clean2/'+baseline,'binary_size_comparable':name=='final',
                     'baseline_binary_bytes':old['binary_bytes'],'final_binary_bytes':full['binary_bytes'],
                     'binary_fraction_change':full['binary_bytes']/old['binary_bytes']-1,
                     'ngram_counts':{order:{'train_only':old['ngram_counts'][order],'full':count,
                         'difference':count-old['ngram_counts'][order],'fraction_change':count/old['ngram_counts'][order]-1}
                         for order,count in full['ngram_counts'].items()}})
    previous.save(out/'train-only-comparison.json',rows)
    return rows


def metadata(out):
    data=json.loads((out/'data/manifest.json').read_text());source_pin=json.loads((out/'source-pin.json').read_text())
    tool_lock=json.loads((ROOT/'corpus/kenlm/source.lock.json').read_text())
    actual_tools={name:{'path':str((TOOLS/name).relative_to(ROOT)),
                       'sha256':source_pin[str((TOOLS/name).relative_to(ROOT))]['sha256']}
                  for name in ('lmplz','build_binary','query')}
    if actual_tools!=tool_lock['binaries']:raise ValueError('Executable hashes do not match the KenLM source lock')
    dictionary_sources={str(p.relative_to(ROOT)):source_pin[str(p.relative_to(ROOT))]['sha256'] for p in round3.dictionary_sources()}
    dictionary={'policy':'Exact case-sensitive flat Chinese + English CSV text union; chinese/phrase/ excluded.',
                'sources':dictionary_sources,'sources_manifest_sha256':canonical_sha(dictionary_sources),**data['dictionary'],
                'runtime_manifests':{language:source_pin[f'mac/SI/Core/Resources/{language}/dictionary-manifest.json'] for language in ('Chinese','English')}}
    contract={'version':'si-kenlm-cleaning-v1','module_sha256':source_pin['scripts/kenlm_cleaning.py']['sha256'],
              'vectors_sha256':source_pin['Tests/KenLMTests/cleaning_vectors.json']['sha256'],
              'unicode_version':unicodedata.unidata_version,'length_unit':'Unicode scalars','maximum_scalars':32,
              'numeric_regex':cleaning.NUMBER.pattern,'garbled_markers':cleaning.GARBLED_MARKERS,'rare_threshold_exclusive':5,
              'frequency_population':'Surviving base-cleaned full train + heldout corpus',
              'reserved_kenlm_tokens_never_emitted':sorted(cleaning.RESERVED),'synthetic_tokens':['<num>','<oov>']}
    if json.loads((ROOT/'Tests/KenLMTests/cleaning_vectors.json').read_text())['contract']!=contract['version']:
        raise ValueError('Cleaning contract version does not match conformance vectors')
    compatibility={'cleaning_version':contract['version'],'cleaning_module_sha256':contract['module_sha256'],
                   'cleaning_vectors_sha256':contract['vectors_sha256'],'dictionary_sources_sha256':dictionary['sources_manifest_sha256'],
                   'protected_vocabulary_sha256':dictionary['sha256'],'full_mapping_sha256':data['mapping']['sha256']}
    meta={'schema_version':1,'created_at':utc_now(),'model':json.loads((out/'final.result.json').read_text()),
          'comparison_model':json.loads((out/'final_large.result.json').read_text()),
          'kenlm':{'version':'archive-sha256:'+tool_lock['archive_sha256'],'binary_format_version':5,'git_commit':None,
                   'git_commit_note':'Author-hosted archive contains no Git revision metadata; no commit is inferred.',
                   'archive_sha256':tool_lock['archive_sha256'],'origin':tool_lock['origin'],'source_lock_sha256':previous.digest(ROOT/'corpus/kenlm/source.lock.json'),
                   'binaries':actual_tools},
          'cleaning':contract,'dictionary':dictionary,'corpus':data,'provenance':json.loads((out/'corpus-provenance.json').read_text()),
          'compatibility':compatibility,'compatibility_sha256':canonical_sha(compatibility),
          'sanity':json.loads((out/'sanity/results.json').read_text()),'sanity_fixture_sha256':previous.digest(FIXTURE),
          'functional_sanity_passed':all(r['passed'] for key,r in json.loads((out/'sanity/results.json').read_text()).items() if key.startswith('final-')),
          'train_only_comparison':comparison(out),
          'independent_heldout_evaluation_performed':False,
          'evaluation_note':'Original heldout is part of final training. Authored sanity sentence scores are not heldout quality metrics.',
          'commands':[json.loads(line) for line in (out/'commands.jsonl').read_text().splitlines()]}
    previous.save(out/'final.meta.json',meta)
    return meta


def report(out):
    meta=metadata(out);s=meta['corpus']['cleaned'];m=meta['model'];large=meta['comparison_model'];p=meta['provenance']
    lines=['## Final full-data clean2 build','',
           'Explicitly authorized final fit. Original train/heldout and every existing train-only model are preserved. Outputs live only in .build/kenlm-final/. The final model is prepared for later app integration; no model is copied into the app by this workflow. final_large.bin is an offline comparison artifact.', '',
           '### Corpus lineage and full-data mapping','',
           f"The original train.txt comes from **{p['pipeline']}**, then the existing first-occurrence deduplication and seeded block split in kenlm-selection-v1. It **did not** undergo the old non-Han-boundary splitting / 4–96-character Han-fragment filtering. The split manifest points to upstream input SHA-256 `{p['upstream_combined_sha256']}`; the v2 manifest matches the retained snapshot at SHA-256 `{p['upstream_manifest_sha256']}`. Its scope explicitly says: `{p['scope_evidence']}`.", '',
           'Code evidence: corpus/prepare_raw_text.py extracts complete raw lines and bypasses the old Han-only cutter; corpus/prepare_kenlm_raw.py uses the shared unigram tokenizer. The v2 tokenizer retains numbers/English/punctuation, uses NFKC and 。！？.!? sentence boundaries and drops >100-token sentences. The existing split already removed exact duplicates; this final run performs no new deduplication or split.', '',
           'Specifically, the old cutter is corpus/clean/chinese.py::segments(minimum=4, maximum=96), called by corpus/prepare.py::prepare_source. The v2 extraction instead calls corpus/prepare_raw_text.py::extract/raw_documents, which writes raw text lines without invoking segments. Its mC4/LCCC branches bypass the old prepared-text path. Evidence code hashes and per-source tokenizer identities are retained in corpus-provenance.json.', '',
           'The no-4–96 statement concerns the actual training text rows. Tokenizer dictionary weights reuse the earlier HanLP frequency reference (SHA-256 '+p['tokenizer_frequency_reference']['sha256']+'); that lexical frequency table is not the earlier cleaned training-text bundle and does not cut these raw-derived text rows.', '',
           '| Original source | SHA-256 |','| --- | --- |']
    for name,state in json.loads((out/'input-pin.json').read_text()).items():lines.append(f"| {name}.txt | `{state['sha256']}` |")
    lines+=['', 'The exact byte concatenation is train first, heldout second (data/full.raw.txt). Counts are recalculated across surviving lines in that entire concatenation before applying clean2. Dictionary protection remains the exact flat Chinese/English CSV text union, excluding chinese/phrase/. No input-method ranking weights are used as occurrence counts. Full raw-token frequencies, outputs and replacement reasons are in data/full-mapping.tsv.', '',
            f"full.clean2.txt: **{s['lines']:,} lines**, **{s['tokens']:,} tokens**, **{s['vocabulary_types']:,} vocabulary types** excluding model-generated special tokens ({s['arpa_vocabulary_including_specials']:,} ARPA unigrams). Deleted garbled lines: **{s['deleted_garbled_lines']:,}**. `<num>`: {s['num_token_count']:,} ({s['num_fraction']:.4%}); `<oov>`: {s['oov_token_count']:,} ({s['oov_fraction']:.4%}). Shares use retained tokens, without EOS.",
            f"Cleaned corpus SHA-256: `{s['sha256']}`; raw concatenation SHA-256: `{meta['corpus']['merged_raw']['sha256']}`.", '',
            'The cleaning module remains scripts/kenlm_cleaning.py, contract si-kenlm-cleaning-v1: whole-line rejection of U+FFFD/锟斤拷/烫烫烫/屯屯屯; numeric forms to `<num>`; >32 Unicode scalars to `<oov>`; non-dictionary words with full surviving frequency <5 to `<oov>`. Source tokenization is preserved, with no new normalization, tokenization or sentence cutting.', '',
            '### Models and train-only comparison','',
            '| Artifact | Prune | MiB | n1 | n2 | n3 | n4 | Discount fallback |','| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |']
    for r in (m,large):lines.append(f"| {r['binary_file']} | {' '.join(map(str,r['prune']))} | {r['binary_bytes']/1048576:.2f} | "+' | '.join(f"{r['ngram_counts'][str(i)]:,}" for i in range(1,5))+f" | {r['discount_fallback']} |")
    lines+=['','Both binaries use -a 22 -q 8 -b 8 trie. The small model is compared against the identically packed train-only clean2 p0123-a22 model. For the large model, n-gram counts use train-only clean2 p0012; its earlier binary omitted -a, so its binary-size difference is not a like-for-like corpus-growth measurement.', '',
            '| Model | Order | Train-only count | Full count | Difference | Change |','| --- | ---: | ---: | ---: | ---: | ---: |']
    for c in meta['train_only_comparison']:
        for order,values in c['ngram_counts'].items():lines.append(f"| {c['model']} | {order} | {values['train_only']:,} | {values['full']:,} | {values['difference']:+,} | {values['fraction_change']:+.3%} |")
    for c in meta['train_only_comparison']:
        if c['binary_size_comparable']:lines+=['',f"Matched-packing size: {c['baseline_binary_bytes']/1048576:.2f} → {c['final_binary_bytes']/1048576:.2f} MiB ({c['binary_fraction_change']:+.3%}).",'']
    lines+=['', 'Growth near 2% is a reasonableness expectation, not a forced threshold: vocabulary remapping and pruning-frequency crossings can change different orders by different proportions.', '',
            '### Functional scoring and loading checks','',
            'There is **no final heldout PPL evaluation**: former heldout lines now participate in training. The 20 natural sentences were authored before scoring, and their 20 bad controls reverse the same cleaned body tokens while preserving final punctuation. Token multisets, lengths and OOV counts are equal within each pair. The fixed criterion is 20/20 natural-sentence wins and median log10-probability margin ≥0.25 per scored token including EOS. This is a synthetic sanity check, not a product-quality benchmark.', '',
            '| Model/loading | Good wins | Median log10 margin/token | Passed | RSSMax MiB |','| --- | ---: | ---: | --- | ---: |']
    for label,r in meta['sanity'].items():lines.append(f"| {label} | {r['wins']}/20 | {r['median_margin_log10_per_token']:.6f} | {r['passed']} | {r['runtime']['rssmax_bytes']/1048576:.2f} |")
    lines+=['', 'Both models contain ordinary nonzero-vocabulary-ID `<num>` and `<oov>` tokens, checked in ARPA and query -v word. final.bin loads with -l lazy and produces exactly the same pair scores as default loading. RSSMax uses native Darwin bytes converted to MiB. The complete 40 sentences, tokenization, raw scores and per-pair margins are retained in sanity/pairs.json and sanity/results.json.', '',
            '| Pair | Natural sentence | Bad token order | Good log10 | Bad log10 | Margin/token |','| --- | --- | --- | ---: | ---: | ---: |']
    pairs=json.loads((out/'sanity/pairs.json').read_text())['pairs']
    for r,pair in zip(meta['sanity']['final-default']['per_pair'],pairs):
        lines.append(f"| {r['pair']} | {pair['good_sentence']} | {' '.join(pair['bad_tokens'])} | {r['good_log10']:.6f} | {r['bad_log10']:.6f} | {r['margin_log10_per_token']:.6f} |")
    lines+=['', '### Commands, metadata and reproducibility','', '```sh','corpus/.venv/bin/python scripts/kenlm_final.py all','```','',
            'The completed run also used the independently resumable acceptance/report stages, reusing the already built model bytes:', '',
            '```sh','corpus/.venv/bin/python scripts/kenlm_final.py sanity','corpus/.venv/bin/python scripts/kenlm_final.py report','```','',
            'The original sources are copied and counted in order by the prepare stage, then cleaned with the recalculated full mapping. Every external command is captured with exact argv, stdin/stdout/stderr paths, status and elapsed time in commands.jsonl. Executed training/build/query commands:', '', '```sh']
    import shlex
    for command in meta['commands']:
        lines.append(shlex.join(command['command'])+' < '+shlex.quote(command['stdin'])+' > '+shlex.quote(command['stdout'])+' 2> '+shlex.quote(command['stderr']))
    lines+=['```','',f"KenLM source: {meta['kenlm']['origin']}, archive SHA-256 `{meta['kenlm']['archive_sha256']}`. The author archive has no Git commit or semantic-release metadata; git_commit is explicitly null. Binary format version is 5, and all three executable hashes are retained. No revision is invented.", '',
            f"final.bin SHA-256: `{m['binary_sha256']}`. final_large.bin SHA-256: `{large['binary_sha256']}`.",
            f"final.meta.json contains model/ARPA hashes and timestamps, KenLM source/executable identity, rule version/module hash/Unicode version, cleaning_vectors.json SHA-256, dictionary source and protected-vocabulary hashes, full mapping/corpus hashes, counts and exact commands. Compatibility fingerprint: `{meta['compatibility_sha256']}`. This prepares future app-side compatibility validation; no native loader or validator is integrated here.", '',
            'git check-ignore confirms .gitignore .build/ covers final.bin, final_large.bin and both ARPAs. None is staged or committed. Original source hashes/mtime/inodes and every existing train-only model are checked before and after. Build/scoring artifacts stay local.']
    validation_file=out/'validation/results.json'
    if validation_file.exists():
        validation=json.loads(validation_file.read_text())
        lines+=['',f"Validation: {validation['python_tests_passed']} Python KenLM tests, {validation['swift_tests_passed']} shared Swift tests and the Debug app build passed. Validation commands: "+'; '.join('`'+command+'`' for command in validation['commands'])+'.']
    audit_file=out/'audit.json'
    if audit_file.exists() and json.loads(audit_file.read_text())['passed']:
        lines+=['','Artifact audit passed; see .build/kenlm-final/audit.json for mapping, corpus, model, metadata and preservation checks.']
    text='\n'.join(lines)+'\n';(out/'README.md').write_text(text)
    readme=ROOT/'README_kenlm_train.md';begin='<!-- KENLM_FINAL_BEGIN -->';end='<!-- KENLM_FINAL_END -->';existing=readme.read_text()
    if begin in existing:
        pre,rest=existing.split(begin,1);_,post=rest.split(end,1);existing=pre+begin+'\n'+text+end+post
    else:existing+='\n'+begin+'\n'+text+end+'\n'
    readme.write_text(existing)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=('all','prepare','train','sanity','report'))
    args=parser.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    pin(OUT);provenance(OUT)
    for name,fn in {'prepare':prepare,'train':train,'sanity':sanity,'report':report}.items():
        if args.stage in ('all',name):fn(OUT)
    pin(OUT,verify_old_models=True)


if __name__=='__main__':main()
