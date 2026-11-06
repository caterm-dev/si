#!/usr/bin/env python3
"""Reproducible local KenLM configuration selection; never train on heldout data."""
import argparse
from contextlib import contextmanager
import gc
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RUN = ROOT / 'corpus/chinese/generated/kenlm-selection-v1'
CONFIGS = {'o3': (3, [0,0,1]), 'o4a': (4,[0,0,1,2]),
           'o4b': (4,[0,0,0,1]), 'o5': (5,[0,0,1,1,2])}
SEED = 20261105
BLOCK_LINES = 1000


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def save(path, value):
    path = Path(path)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')


@contextmanager
def staged(target):
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.'+target.name+'-', dir=target.parent))
    try:
        yield stage
        if target.exists():
            raise FileExistsError(target)
        stage.rename(target)
    except BaseException:
        if stage.exists():
            failed = stage.with_name('failed-'+stage.name.lstrip('.'))
            stage.rename(failed)
            print('Failure artifacts preserved: '+str(failed), flush=True)
        raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def block_split(block, seed=SEED):
    # Zero-based block index after deduplication. Never use Python's hash().
    value = hashlib.sha256(f'kenlm-block-v1:{seed}:{block}'.encode('ascii')).digest()
    return 'heldout' if int.from_bytes(value[:8], 'big') % 10000 < 200 else 'train'


def line_digest(line):
    return hashlib.sha256(line).digest()


def validate_line(raw):
    line = raw[:-1] if raw.endswith(b'\n') else raw
    if not line or line[:1]==b' ' or line[-1:]==b' ' or b'  ' in line or any(c in line for c in (b'\r',b'\t')):
        raise ValueError('Input must contain nonempty single-space-separated LF lines')
    line.decode('utf-8', errors='strict')
    if not set(line.split(b' ')).isdisjoint({b'<s>',b'</s>',b'<unk>'}):
        raise ValueError('Input must not contain KenLM sentence/unknown markers')
    return line+b'\n'


def verify_split(directory):
    counts = {}
    train_hashes = set()
    for name in ('train','heldout'):
        lines = tokens = 0
        heldout_hashes = set()
        with (directory/(name+'.txt')).open('rb') as handle:
            for raw in handle:
                line = validate_line(raw)
                key = line_digest(line)
                if name == 'train':
                    if key in train_hashes:
                        raise ValueError('Duplicate train line')
                    train_hashes.add(key)
                else:
                    if key in train_hashes:
                        raise ValueError('Train/heldout line overlap')
                    if key in heldout_hashes:
                        raise ValueError('Duplicate heldout line')
                    heldout_hashes.add(key)
                lines += 1
                tokens += line.count(b' ')+1
        counts[name] = {'lines': lines, 'tokens': tokens, 'bytes': (directory/(name+'.txt')).stat().st_size,
                        'sha256': digest(directory/(name+'.txt'))}
    return counts


def prepare(input_path, run, seed=SEED):
    target = run / 'data'
    if target.exists():
        record = json.loads((target/'manifest.json').read_text())
        if record['input']['sha256'] != digest(input_path) or record['seed'] != seed:
            raise ValueError('Existing split belongs to different input/seed')
        for name, expected in record['splits'].items():
            if digest(target/(name+'.txt')) != expected['sha256']:
                raise ValueError('Existing split modified')
        print('Verified completed deduplication/split', flush=True)
        return record
    with staged(target) as stage:
        seen = set()
        input_hash = hashlib.sha256()
        raw_lines = unique = duplicates = 0
        totals = {name:{'lines':0,'tokens':0} for name in ('train','heldout')}
        started = last_report = time.monotonic()
        with input_path.open('rb') as source, (stage/'deduplicated.txt').open('wb') as dedup, \
                (stage/'train.txt').open('wb') as train, (stage/'heldout.txt').open('wb') as heldout:
            destinations = {'train':train, 'heldout':heldout}
            for raw in source:
                input_hash.update(raw)
                line = validate_line(raw)
                raw_lines += 1
                key = line_digest(line)
                if key in seen:
                    duplicates += 1
                else:
                    seen.add(key)
                    name = block_split(unique // BLOCK_LINES, seed)
                    destinations[name].write(line)
                    dedup.write(line)
                    unique += 1
                    totals[name]['lines'] += 1
                    totals[name]['tokens'] += line.count(b' ')+1
                if raw_lines % 100000 == 0 and time.monotonic()-last_report >= 10:
                    print(f'Dedup: {raw_lines:,} input / {unique:,} unique / {duplicates:,} duplicates',flush=True)
                    last_report = time.monotonic()
        seen.clear()
        del seen
        gc.collect()
        print('Independently checking train/heldout uniqueness and disjointness',flush=True)
        measured = verify_split(stage)
        for name in totals:
            assert all(measured[name][k]==totals[name][k] for k in ('lines','tokens'))
        if measured['train']['lines'] < 100000 or not measured['heldout']['lines']:
            # Small synthetic fixtures are still useful; smoke enforces its own size.
            print('Small split: production smoke requires at least 100,000 train lines',flush=True)
        with (stage/'train.txt').open('rb') as source, (stage/'smoke-train.txt').open('wb') as output:
            for line in itertools.islice(source,100000):output.write(line)
        with (stage/'heldout.txt').open('rb') as source, (stage/'smoke-heldout.txt').open('wb') as output:
            for line in itertools.islice(source,10000):output.write(line)
        record = {'schema_version':1,'input':{'path':str(input_path),'sha256':input_hash.hexdigest(),'lines':raw_lines},
                  'seed':seed,'block_lines':BLOCK_LINES,'hash':'SHA-256',
                  'assignment':"SHA256(ASCII('kenlm-block-v1:{seed}:{zero_based_block}')) first 8 bytes big-endian modulo 10000 < 200 => heldout; blocks of deduplicated lines",
                  'unique_lines':unique,'duplicate_lines_removed':duplicates,'splits':measured,
                  'heldout_line_fraction':measured['heldout']['lines']/unique,
                  'deduplicated':{'path':'deduplicated.txt','sha256':digest(stage/'deduplicated.txt')},
                  'no_duplicate_or_shared_line_hashes':True,'seconds':time.monotonic()-started}
        save(stage/'manifest.json',record)
    print(json.dumps(record,ensure_ascii=False),flush=True)
    return record


def audit_blocks(run):
    data=run/'data';record=json.loads((data/'manifest.json').read_text())
    with (data/'deduplicated.txt').open('rb') as source, (data/'train.txt').open('rb') as train, (data/'heldout.txt').open('rb') as heldout:
        files={'train':train,'heldout':heldout};blocks=lines=0
        while True:
            group=list(itertools.islice(source,BLOCK_LINES))
            if not group:break
            digest_bytes=hashlib.sha256(f"kenlm-block-v1:{record['seed']}:{blocks}".encode('ascii')).digest()
            name='heldout' if int.from_bytes(digest_bytes[:8],'big')%10000<200 else 'train'
            expected=b''.join(group)
            if files[name].read(len(expected))!=expected:
                raise ValueError('Full block-routing audit failed at block '+str(blocks))
            blocks+=1;lines+=len(group)
        if train.read(1) or heldout.read(1) or lines!=record['unique_lines']:
            raise ValueError('Split has unmatched extra data or missing unique lines')
    for name,expected in record['splits'].items():
        if digest(data/(name+'.txt'))!=expected['sha256']:
            raise ValueError('Split checksum changed')
    if digest(data/'deduplicated.txt')!=record['deduplicated']['sha256']:
        raise ValueError('Deduplicated file checksum changed')
    prefix_checks={}
    for source_name,target_name,limit in [('train.txt','smoke-train.txt',100000),('heldout.txt','smoke-heldout.txt',10000)]:
        check=hashlib.sha256();count=0
        with (data/source_name).open('rb') as source:
            for line in itertools.islice(source,limit):check.update(line);count+=1
        if check.hexdigest()!=digest(data/target_name):raise ValueError('Smoke prefix changed')
        prefix_checks[target_name]={'lines':count,'sha256':check.hexdigest()}
    result={'blocks_checked':blocks,'unique_lines_checked':lines,'all_block_routes_byte_equal':True,
            'split_checksums_valid':True,'smoke_prefixes':prefix_checks}
    save(run/'block-audit.json',result)
    print(json.dumps(result),flush=True)
    return result


def run_command(command, input_path, output_path, log_path, journal):
    started = time.monotonic()
    print(shlex.join(map(str,command)),flush=True)
    with input_path.open('rb') as source, output_path.open('wb') as output, log_path.open('wb') as log:
        completed = subprocess.run(list(map(str,command)),stdin=source,stdout=output,stderr=log)
    result={'command':list(map(str,command)),'stdin':str(input_path),'stdout':str(output_path),
            'stderr':str(log_path),'exit_code':completed.returncode,'seconds':time.monotonic()-started}
    with journal.open('a') as handle:handle.write(json.dumps(result)+'\n')
    return result


def parse_query(text):
    def value(label):
        match = re.search(r'^'+re.escape(label)+r'\s*[:=]\s*([^\s]+)',text,re.I | re.M)
        if not match:raise ValueError('Missing query statistic: '+label)
        return float(match.group(1))
    result={'perplexity_including_oovs':value('Perplexity including OOVs'),
            'perplexity_excluding_oovs':value('Perplexity excluding OOVs'),
            'oovs':int(value('OOVs')), 'query_tokens':int(value('Tokens'))}
    if any(not math.isfinite(result[k]) or result[k]<=0 for k in ('perplexity_including_oovs','perplexity_excluding_oovs')):
        raise ValueError('Nonfinite/invalid perplexity')
    return result


def train_one(name, run, tools, smoke=False):
    order,prune = CONFIGS[name]
    data=run/'data'
    split=json.loads((data/'manifest.json').read_text())
    if smoke and split['splits']['train']['lines']<100000:
        raise ValueError('Smoke requires the first 100,000 train lines')
    training=data/('smoke-train.txt' if smoke else 'train.txt')
    evaluation=data/('smoke-heldout.txt' if smoke else 'heldout.txt')
    identity={'training_sha256':digest(training),'evaluation_sha256':digest(evaluation),
              'tools':{tool:digest(tools/tool) for tool in ('lmplz','build_binary','query')},
              'order':order,'prune':prune,'memory':'40%','temporary_directory':'/tmp',
              'binary_type':'trie','probability_bits':8,'backoff_bits':8,'smoke':smoke}
    if not smoke and (identity['training_sha256']!=split['splits']['train']['sha256'] or identity['evaluation_sha256']!=split['splits']['heldout']['sha256']):
        raise ValueError('Train or heldout differs from the verified split')
    target=run/('smoke' if smoke else 'models')/name
    if target.exists():
        record=json.loads((target/'result.json').read_text())
        if record['identity']!=identity or digest(target/'model.trie')!=record['binary_sha256']:
            raise ValueError('Completed model has different inputs/options/tools')
        print('Verified completed '+str(target),flush=True)
        return record
    with staged(target) as stage:
        journal=stage/'commands.jsonl'
        arpa=stage/'model.arpa'
        command=[tools/'lmplz','-o',str(order),'-S','40%','-T','/tmp','--prune',*map(str,prune)]
        attempted=run_command(command,training,arpa,stage/'lmplz.log',journal)
        estimation_seconds=attempted['seconds']
        fallback=False
        if attempted['exit_code']:
            message=(stage/'lmplz.log').read_text(errors='replace')
            if '--discount_fallback' not in message and 'BadDiscount' not in message:
                raise RuntimeError('lmplz failed; see '+str(stage/'lmplz.log'))
            fallback=True
            command.append('--discount_fallback')
            attempted=run_command(command,training,arpa,stage/'lmplz-fallback.log',journal)
            estimation_seconds+=attempted['seconds']
            if attempted['exit_code']:raise RuntimeError('lmplz fallback failed')
        binary=stage/'model.trie'
        command=[tools/'build_binary','-S','40%','-T','/tmp','-q','8','-b','8','trie',arpa,binary]
        built=run_command(command,Path('/dev/null'),stage/'build_binary.stdout',stage/'build_binary.log',journal)
        if built['exit_code']:raise RuntimeError('build_binary failed')
        command=[tools/'query','-v','summary',binary]
        queried=run_command(command,evaluation,stage/'query.stdout',stage/'query.stderr',journal)
        if queried['exit_code']:raise RuntimeError('query failed')
        metrics=parse_query((stage/'query.stdout').read_text()+'\n'+(stage/'query.stderr').read_text())
        with arpa.open() as handle:
            ngram_counts={}
            for line in handle:
                match=re.fullmatch(r'ngram (\d+)=(\d+)\s*',line)
                if match:ngram_counts[match.group(1)]=int(match.group(2))
                if line.startswith('\\1-grams:'):break
        with evaluation.open('rb') as handle:
            expected_query_tokens=sum(line.count(b' ')+2 for line in handle)
        if metrics['query_tokens']!=expected_query_tokens:
            raise ValueError('query token count does not cover the evaluation file including EOS')
        result={'configuration':name, 'ngram_counts':ngram_counts,'identity':identity,'discount_fallback':fallback,
                'training_seconds':estimation_seconds,'binary_build_seconds':built['seconds'],
                'total_training_seconds':estimation_seconds+built['seconds'],
                'query_seconds':queried['seconds'],'binary_bytes':binary.stat().st_size,
                'binary_sha256':digest(binary),**metrics}
        save(stage/'result.json',result)
        # Preserve quantized trie, logs, metrics and commands; discard only this
        # run's reproducible ARPA intermediate after a successful query.
        arpa.unlink()
    print(json.dumps(result),flush=True)
    return result


def write_report(run, results, readme=None):
    split=json.loads((run/'data/manifest.json').read_text())
    if {r['configuration'] for r in results}!=set(CONFIGS) or len(results)!=len(CONFIGS):
        raise ValueError('All four completed configurations are required')
    for result in results:
        name=result['configuration'];folder=run/'models'/name
        order,prune=CONFIGS[name]
        identity=result['identity']
        if (identity['order']!=order or identity['prune']!=prune or identity['memory']!='40%'
                or identity['temporary_directory']!='/tmp' or identity['binary_type']!='trie'
                or identity['probability_bits']!=8 or identity['backoff_bits']!=8):
            raise ValueError('Result options differ from the requested configuration')
        if result['identity']['smoke']:
            raise ValueError('Smoke results cannot be used for configuration selection')
        if result['identity']['training_sha256']!=split['splits']['train']['sha256'] or result['identity']['evaluation_sha256']!=split['splits']['heldout']['sha256']:
            raise ValueError('Results do not belong to the frozen train/heldout split')
        if digest(folder/'model.trie')!=result['binary_sha256'] or (folder/'model.trie').stat().st_size!=result['binary_bytes']:
            raise ValueError('Completed binary changed')
        parsed=parse_query((folder/'query.stdout').read_text()+'\n'+(folder/'query.stderr').read_text())
        if any(parsed[key]!=result[key] for key in parsed):
            raise ValueError('Recorded metrics disagree with raw query summary')
        if parsed['query_tokens']!=split['splits']['heldout']['tokens']+split['splits']['heldout']['lines']:
            raise ValueError('Incomplete heldout query coverage')
    if len({r['oovs'] for r in results})!=1:
        raise ValueError('Unexpected OOV-count disagreement with unpruned unigram vocabularies')
    best=min(r['perplexity_including_oovs'] for r in results)
    eligible=[r for r in results if r['perplexity_including_oovs']<=best*1.01]
    chosen=min(eligible,key=lambda r:(r['binary_bytes'],r['total_training_seconds']))
    selection={'results':results,'recommended_configuration':chosen['configuration'],
               'rule':'Smallest trie within 1% of the best including-OOV heldout PPL; break exact size ties by total training time',
               'best_including_oov_perplexity':best,'recommended_relative_ppl_gap':chosen['perplexity_including_oovs']/best-1,
               'training_scope':'train.txt only','final_combined_data_training_performed':False}
    save(run/'selection.json',selection)
    import csv
    columns=['configuration','perplexity_including_oovs','perplexity_excluding_oovs','oovs','binary_bytes','training_seconds','binary_build_seconds','total_training_seconds','query_seconds','discount_fallback']
    with (run/'comparison.csv').open('w',newline='') as handle:
        writer=csv.DictWriter(handle,fieldnames=columns,extrasaction='ignore');writer.writeheader();writer.writerows(results)
    lines=['| Config | Order / prune | PPL incl. OOV | PPL excl. OOV | OOV tokens | Trie MiB | lmplz seconds | Binary seconds | Total train seconds |',
           '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for r in results:
        order,prune=CONFIGS[r['configuration']]
        lines.append(f"| {r['configuration']} | {order} / {' '.join(map(str,prune))} | {r['perplexity_including_oovs']:.6f} | {r['perplexity_excluding_oovs']:.6f} | {r['oovs']:,} | {r['binary_bytes']/1048576:.2f} | {r['training_seconds']:.2f} | {r['binary_build_seconds']:.2f} | {r['total_training_seconds']:.2f} |")
    lines+=['',f"Recommendation: **{chosen['configuration']}**. Its including-OOV PPL is {(chosen['perplexity_including_oovs']/best-1)*100:.3f}% above the best; it is the smallest trie satisfying the explicit 1% tolerance.",
            '',f"All four score {split['splits']['heldout']['lines']:,} heldout lines and {split['splits']['heldout']['tokens']+split['splits']['heldout']['lines']:,} tokens including EOS. OOV counts agree. Values are measured from quantized trie binaries.",
            '', 'Final combined-data retraining: **not run**, pending the user\'s configuration confirmation.']
    text='\n'.join(lines)+'\n'
    (run/'comparison.md').write_text(text)
    if readme:
        original=readme.read_text();start='<!-- KENLM_RESULTS_BEGIN -->';end='<!-- KENLM_RESULTS_END -->'
        before,remainder=original.split(start,1);_,after=remainder.split(end,1)
        readme.write_text(before+start+'\n'+text+end+after)
    print(text,flush=True)
    return selection


def compare(run, tools):
    for name in CONFIGS:train_one(name,run,tools,smoke=True)
    results=[]
    for name in CONFIGS:
        results.append(train_one(name,run,tools))
        save(run/'comparison.json',results)
    write_report(run,results,ROOT/'README_kenlm_train.md')
    return results


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=('prepare','smoke','compare','report','audit'))
    parser.add_argument('--input',type=Path,default=ROOT/'corpus/chinese/generated/kenlm-words-v2/kenlm-input.txt')
    parser.add_argument('--run',type=Path,default=DEFAULT_RUN)
    parser.add_argument('--tools',type=Path,default=ROOT/'corpus/.cache/kenlm-build/bin')
    parser.add_argument('--seed',type=int,default=SEED)
    args=parser.parse_args();args.run.mkdir(parents=True,exist_ok=True)
    if args.command=='prepare':prepare(args.input,args.run,args.seed)
    elif args.command=='audit':audit_blocks(args.run)
    elif args.command=='report':
        results=[json.loads((args.run/'models'/name/'result.json').read_text()) for name in CONFIGS]
        write_report(args.run,results,ROOT/'README_kenlm_train.md')
    elif args.command=='smoke':
        for name in CONFIGS:train_one(name,args.run,args.tools,smoke=True)
    else:compare(args.run,args.tools)


if __name__=='__main__':main()
