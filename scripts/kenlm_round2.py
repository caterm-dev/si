#!/usr/bin/env python3
"""Second KenLM experiment on immutable existing splits; no corpus preparation."""
import argparse
from collections import Counter
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import unicodedata

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'corpus'))
from kenlm_train import digest, save, staged, run_command, parse_query
OLD=ROOT/'corpus/chinese/generated/kenlm-selection-v1'
OUT=ROOT/'.build/kenlm-round2'
TOOLS=ROOT/'corpus/.cache/kenlm-build/bin'
NEW={'o5c':(5,[0,0,1,2,3]),'o4d':(4,[0,1,2,3]),'o4e':(4,[0,0,2,3]),'o3b':(3,[0,1,2])}
NAMES=['o3','o4a','o4b','o5',*NEW]


def pin_inputs(out):
    out.mkdir(parents=True,exist_ok=True)
    manifest=json.loads((OLD/'data/manifest.json').read_text())
    state={}
    for name in ('train','heldout'):
        p=OLD/'data'/(name+'.txt');s=p.stat();h=digest(p)
        if h!=manifest['splits'][name]['sha256']:raise ValueError('Original split checksum mismatch')
        state[name]={'sha256':h,'bytes':s.st_size,'mtime_ns':s.st_mtime_ns,'inode':s.st_ino}
    path=out/'input-pin.json'
    if path.exists() and json.loads(path.read_text())!=state:raise ValueError('Input state changed')
    if not path.exists():save(path,state)
    return manifest


def arpa_header(path):
    lines=[];counts={}
    with path.open() as f:
        for line in f:
            lines.append(line)
            m=re.fullmatch(r'ngram (\d+)=(\d+)\s*',line)
            if m:counts[m[1]]=int(m[2])
            if line.startswith('\\1-grams:'):break
    if not counts or not lines[-1].startswith('\\1-grams:'):raise ValueError('Missing ARPA unigram section')
    return ''.join(lines),counts


def estimate(stage,order,prune):
    arpa=stage/'model.arpa';journal=stage/'commands.jsonl'
    command=[TOOLS/'lmplz','-o',str(order),'-S','40%','-T','/tmp','--prune',*map(str,prune)]
    result=run_command(command,OLD/'data/train.txt',arpa,stage/'lmplz.log',journal)
    fallback=False
    if result['exit_code']:
        text=(stage/'lmplz.log').read_text(errors='replace')
        if '--discount_fallback' not in text and 'BadDiscount' not in text:raise RuntimeError('lmplz failed')
        fallback=True;command.append('--discount_fallback')
        retried=run_command(command,OLD/'data/train.txt',arpa,stage/'lmplz-fallback.log',journal)
        result['seconds']+=retried['seconds']
        if retried['exit_code']:raise RuntimeError('lmplz fallback failed')
    header,counts=arpa_header(arpa);(stage/'arpa-header.txt').write_text(header)
    return arpa,counts,fallback,result['seconds']


def build(stage,arpa,quantized=True):
    binary=stage/'model.trie'
    cmd=[TOOLS/'build_binary','-S','40%','-T','/tmp']
    if quantized:cmd+=['-q','8','-b','8']
    cmd+=['trie',arpa,binary]
    r=run_command(cmd,Path('/dev/null'),stage/'build.stdout',stage/'build.log',stage/'commands.jsonl')
    if r['exit_code']:raise RuntimeError('Binary construction failed')
    return binary,r['seconds']


def evaluate(binary,directory):
    directory.mkdir(parents=True,exist_ok=True)
    r=run_command([TOOLS/'query','-v','summary',binary],OLD/'data/heldout.txt',directory/'query.stdout',directory/'query.stderr',directory/'commands.jsonl')
    if r['exit_code']:raise RuntimeError('Query failed')
    metrics=parse_query((directory/'query.stdout').read_text()+'\n'+(directory/'query.stderr').read_text())
    data=json.loads((OLD/'data/manifest.json').read_text())['splits']['heldout']
    if metrics['query_tokens']!=data['tokens']+data['lines']:raise ValueError('Incomplete heldout coverage')
    return {**metrics,'query_seconds':r['seconds'],'binary_bytes':binary.stat().st_size,'binary_sha256':digest(binary)}


def train_all(out):
    pin_inputs(out)
    for name,(order,prune) in NEW.items():
        target=out/'models'/name
        if target.exists():
            r=json.loads((target/'result.json').read_text())
            if digest(target/'model.trie')!=r['binary_sha256']:raise ValueError('Existing model changed')
            continue
        with staged(target) as stage:
            arpa,counts,fallback,seconds=estimate(stage,order,prune)
            binary,build_seconds=build(stage,arpa)
            result={'configuration':name,'order':order,'prune':prune,'ngram_counts':counts,
                    'discount_fallback':fallback,'training_seconds':seconds,'binary_build_seconds':build_seconds,
                    **evaluate(binary,stage)}
            save(stage/'result.json',result);arpa.unlink()
        print('Completed '+name,flush=True)


def o4a_extra(out):
    pin_inputs(out);target=out/'o4a-unquantized'
    if target.exists():return
    with staged(target) as stage:
        arpa,counts,fallback,seconds=estimate(stage,4,[0,0,1,2])
        old=json.loads((OLD/'models/o4a/result.json').read_text())
        if counts!=old['ngram_counts']:raise ValueError('Reconstructed o4a counts differ')
        binary,build_seconds=build(stage,arpa,False)
        result={'configuration':'o4a-unquantized','order':4,'prune':[0,0,1,2],'ngram_counts':counts,
                'discount_fallback':fallback,'training_seconds':seconds,'binary_build_seconds':build_seconds,
                **evaluate(binary,stage)}
        save(stage/'result.json',result)
    print('Completed unquantized o4a; retained ARPA for vocabulary inspection',flush=True)


def quantization_control(out):
    target=out/'o4a-requantized-control'
    if target.exists():return
    with staged(target) as stage:
        arpa=out/'o4a-unquantized/model.arpa'
        binary,seconds=build(stage,arpa,True)
        result=evaluate(binary,stage)
        old=json.loads((OLD/'models/o4a/result.json').read_text())
        result.update(configuration='o4a-requantized-control',binary_build_seconds=seconds,
                      same_binary_as_round1=result['binary_sha256']==old['binary_sha256'],
                      including_oov_ppl_difference=result['perplexity_including_oovs']-old['perplexity_including_oovs'])
        save(stage/'result.json',result)


def noise_reasons(word):
    reasons=[]
    if word.isdecimal():reasons.append('pure_digits')
    elif re.fullmatch(r'[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?',word):reasons.append('numeric_form')
    if '\ufffd' in word or any(unicodedata.category(c) in ('Cc','Cf','Co','Cn','Cs') for c in word) or any(t in word for t in ('锟斤拷','烫烫烫','屯屯屯')):
        reasons.append('garbled_or_nonprinting')
    if len(word)>32 or len(word.encode('utf-8'))>128:reasons.append('long_token')
    return reasons


def vocabulary(out):
    pin_inputs(out);target=out/'vocabulary'
    if target.exists():return
    arpa=out/'o4a-unquantized/model.arpa'
    with staged(target) as stage:
        vocab=set();header,counts=arpa_header(arpa)
        with arpa.open() as f:
            for line in f:
                if line.startswith('\\1-grams:'):break
            for line in f:
                if line.startswith('\\2-grams:'):break
                if line.strip():vocab.add(line.split()[1].encode('utf-8'))
        if len(vocab)!=counts['1']:raise ValueError('ARPA vocabulary count mismatch')
        counter=Counter();lines=0;last=time.monotonic()
        with (OLD/'data/train.txt').open('rb') as f:
            for line in f:
                counter.update(line.split());lines+=1
                if lines%100000==0 and time.monotonic()-last>=15:
                    print(f'Vocabulary counts: {lines:,} train lines',flush=True);last=time.monotonic()
        specials={b'<s>',b'</s>',b'<unk>'};lexical=vocab-specials
        if set(counter)!=lexical:raise ValueError('Train vocabulary differs from ARPA lexical vocabulary')
        singleton=sum(n==1 for n in counter.values());le5=sum(n<=5 for n in counter.values())
        suspects=[];category_words=Counter();category_tokens=Counter()
        for word,count in counter.items():
            text=word.decode('utf-8');reasons=noise_reasons(text)
            if reasons:
                suspects.append({'word':text,'count':count,'reasons':reasons})
                for reason in reasons:category_words[reason]+=1;category_tokens[reason]+=count
        suspects.sort(key=lambda r:(-r['count'],r['word'].encode('utf-8')))
        record={'arpa_vocabulary_including_specials':len(vocab),'specials':sorted(x.decode() for x in specials),
                'lexical_vocabulary':len(lexical),'train_tokens':sum(counter.values()),'train_lines':lines,
                'once':singleton,'at_most_five':le5,'once_fraction':singleton/len(lexical),'at_most_five_fraction':le5/len(lexical),
                'suspect_word_types':len(suspects),'categories_word_types':dict(category_words),'categories_tokens':dict(category_tokens),
                'noise_policy':'Heuristics only; pure decimal digits, signed/decimal/exponent numeric forms, replacement/control/private/unassigned characters or explicit mojibake strings, >32 Unicode scalars or >128 UTF-8 bytes. Valid numbers/names may be flagged. No data is removed.',
                'top30':suspects[:30],
                'top10_by_category':{reason:[r for r in suspects if reason in r['reasons']][:10] for reason in category_words}}
        save(stage/'statistics.json',record)
    print('Vocabulary statistics complete',flush=True)


def eval_all(out):
    for name in NAMES+['o4a-unquantized']:
        if name in NEW:folder=out/'models'/name
        elif name=='o4a-unquantized':folder=out/name
        else:folder=OLD/'models'/name
        old=json.loads((folder/'result.json').read_text());dest=out/'evaluations'/name
        if (dest/'result.json').exists():continue
        metrics=evaluate(folder/'model.trie',dest)
        if metrics['binary_sha256']!=old['binary_sha256']:raise ValueError('Model changed')
        save(dest/'result.json',{'configuration':name,'ngram_counts':old['ngram_counts'],
                                'ngram_count_source':str(folder/'arpa-header.txt' if (folder/'arpa-header.txt').exists() else folder/'result.json'),**metrics})


def parse_runtime(text):
    def number(label):
        m=re.search(r'\b'+re.escape(label)+r':([0-9.eE+-]+)',text)
        if not m:raise ValueError('Missing runtime statistic '+label)
        return float(m[1])
    raw=int(number('RSSMax'))
    return {'query_real_seconds':number('real'),'query_cpu_seconds':number('CPU'),
            'query_user_seconds':number('user'),'query_system_seconds':number('sys'),
            'rssmax_raw':raw,'rssmax_raw_label':'kB (upstream print label)',
            'rssmax_bytes':raw if sys.platform=='darwin' else raw*1024,
            'rssmax_unit_note':'On Darwin ru_maxrss is bytes; KenLM prints the literal kB label without converting it.'}


def performance(out):
    target=out/'performance';target.mkdir(exist_ok=True)
    sample=target/'heldout-first-200000.txt'
    if not sample.exists():
        with (OLD/'data/heldout.txt').open('rb') as f,sample.open('wb') as g:
            for line in itertools.islice(f,200000):g.write(line)
    with sample.open('rb') as f:words=sum(line.count(b' ')+2 for line in f)
    results=[]
    for name in ('o3','o4a','o5','o4b'):
        folder=target/name;folder.mkdir(exist_ok=True)
        for phase in ('first','hot'):
            result_path=folder/(phase+'.json')
            if result_path.exists():results.append(json.loads(result_path.read_text()));continue
            purge=None
            if phase=='first':
                p=subprocess.run(['/usr/sbin/purge'],capture_output=True,text=True)
                purge={'command':['/usr/sbin/purge'],'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
            binary=OLD/'models'/name/'model.trie';cmd=[str(TOOLS/'query'),'-v','summary',str(binary)]
            start=time.monotonic()
            with sample.open('rb') as f,(folder/(phase+'.stdout')).open('wb') as g,(folder/(phase+'.stderr')).open('wb') as log:
                process=subprocess.Popen(cmd,stdin=f,stdout=g,stderr=log)
                _,status,usage=os.wait4(process.pid,0);process.returncode=os.waitstatus_to_exitcode(status)
            if process.returncode:raise RuntimeError('Runtime query failed')
            text=(folder/(phase+'.stderr')).read_text();metrics=parse_runtime(text)
            q=parse_query((folder/(phase+'.stdout')).read_text())
            if q['query_tokens']!=words:raise ValueError('Runtime query prefix coverage mismatch')
            result={'configuration':name,'phase':phase,'command':cmd,'prefix_lines':200000,'prefix_sha256':digest(sample),
                    'purge':purge,'cold_cache_established':bool(purge and purge['exit_code']==0),
                    'first_run_label':'purge-requested cold attempt' if purge and purge['exit_code']==0 else 'cache-uncontrolled first run' if phase=='first' else 'immediate second fresh-process hot run',
                    'wrapper_wall_seconds':time.monotonic()-start,'wait4_cpu_seconds':usage.ru_utime+usage.ru_stime,
                    'wait4_rssmax_native':usage.ru_maxrss,**metrics,**q}
            save(result_path,result);results.append(result)
    save(target/'results.json',results)


def report(out):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    rows=[json.loads((out/'evaluations'/n/'result.json').read_text()) for n in NAMES+['o4a-unquantized']]
    perf=json.loads((out/'performance/results.json').read_text());p={(r['configuration'],r['phase']):r for r in perf}
    vocab=json.loads((out/'vocabulary/statistics.json').read_text())
    lines=['## Second round: existing splits unchanged','',
           'All fits use the original train split only. No corpus rewriting, splitting or final combined-data retraining is performed.',
           'Models o5c/o4d/o4e/o3b use -S 40% -T /tmp and -q 8 -b 8 trie; no -a option. o4a ARPA was reconstructed with its original options for the unquantized control and vocabulary inspection.',
           '', '| Config | MiB | PPL incl. OOV | PPL excl. OOV | n1 | n2 | n3 | n4 | n5 | Query first / hot s | RSS first / hot MiB |',
           '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |']
    for r in rows:
        n=r['configuration'];counts=r['ngram_counts']
        runtime='not requested';rss='not requested'
        if (n,'first') in p:
            a,b=p[n,'first'],p[n,'hot'];runtime=f"{a['query_real_seconds']:.4f} / {b['query_real_seconds']:.4f}";rss=f"{a['rssmax_bytes']/1048576:.1f} / {b['rssmax_bytes']/1048576:.1f}"
        lines.append('| '+n+f" | {r['binary_bytes']/1048576:.2f} | {r['perplexity_including_oovs']:.6f} | {r['perplexity_excluding_oovs']:.6f} | "+' | '.join(f"{int(counts[str(i)]):,}" if str(i) in counts else '—' for i in range(1,6))+f' | {runtime} | {rss} |')
    lines+=['','All complete-heldout evaluations score 16,474,727 tokens including EOS. Runtime columns use only the first 200,000 heldout lines, not the complete-heldout evaluation duration.',
            'Cache purge was denied by macOS (Operation not permitted). First results are cache-uncontrolled, not genuine cold-start measurements; hot results are immediate second fresh-process queries. One pair per model provides descriptive measurements only.',
            'KenLM incorrectly labels native Darwin ru_maxrss values as kB; the table converts the actual byte values to MiB. Original output and independent wait4 metrics are retained.',
            '', '| Runtime model | First real s | First CPU s | First RSS MiB | Hot real s | Hot CPU s | Hot RSS MiB |',
            '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for name in ('o3','o4a','o5','o4b'):
        a,b=p[name,'first'],p[name,'hot']
        lines.append(f"| {name} | {a['query_real_seconds']:.6f} | {a['query_cpu_seconds']:.6f} | {a['rssmax_bytes']/1048576:.2f} | {b['query_real_seconds']:.6f} | {b['query_cpu_seconds']:.6f} | {b['rssmax_bytes']/1048576:.2f} |")
    q=next(r for r in rows if r['configuration']=='o4a');u=next(r for r in rows if r['configuration']=='o4a-unquantized')
    lines+=['',f"o4a quantization: including-OOV PPL {q['perplexity_including_oovs']:.6f} (8/8 bits) versus {u['perplexity_including_oovs']:.6f} (unquantized); size {q['binary_bytes']/1048576:.2f} versus {u['binary_bytes']/1048576:.2f} MiB.",
            f"Quantization reduces size by {1-q['binary_bytes']/u['binary_bytes']:.2%}, with an including-OOV PPL increase of {q['perplexity_including_oovs']-u['perplexity_including_oovs']:.6f} ({q['perplexity_including_oovs']/u['perplexity_including_oovs']-1:.4%}).",
            'o4d is smaller and has lower PPL than o3 in this experiment. o4b retains the lowest PPL among the eight quantized configurations, at the largest binary size.',
            '',f"ARPA vocabulary: {vocab['arpa_vocabulary_including_specials']:,} including <s>, </s>, <unk>; {vocab['lexical_vocabulary']:,} lexical tokens. Raw train occurrence counts: exactly once {vocab['once']:,} ({vocab['once_fraction']:.4%}); at most five {vocab['at_most_five']:,} ({vocab['at_most_five_fraction']:.4%}). Fractions exclude the three synthetic special tokens.",
            '',vocab['noise_policy'],'','| Suspect token | Train occurrences | Flags |','| --- | ---: | --- |']
    for r in vocab['top30']:lines.append(f"| {r['word'].replace('|','&#124;')} | {r['count']:,} | {', '.join(r['reasons'])} |")
    lines+=['','The global top 30 are mostly numbers because they are frequent. Category totals below also expose rare long tokens; categories can overlap.',
            '', '| Suspect category | Word types | Train occurrences |', '| --- | ---: | ---: |']
    for category,count in vocab['categories_word_types'].items():
        lines.append(f"| {category} | {count:,} | {vocab['categories_tokens'][category]:,} |")
    lines+=['', 'For example, U+FFFD (replacement character) occurs 284,867 times and 锟斤拷 occurs 378 times. The most frequent long token is `conversaramportelefonenasegunda-feirasobrequestesbilateraiss` (9 occurrences). Full per-category examples are retained in [.build/kenlm-round2/vocabulary/statistics.json](.build/kenlm-round2/vocabulary/statistics.json).']
    control_file=out/'o4a-requantized-control/result.json'
    if control_file.exists():
        control=json.loads(control_file.read_text())
        lines += ['',f"Requantizing the reconstructed ARPA reproduces the original o4a binary: {control['same_binary_as_round1']}; including-OOV PPL difference {control['including_oov_ppl_difference']:.12g}. This checks the quantized/unquantized comparison against a common ARPA."]
    lines+=['','Reproduce without modifying corpus files:', '```sh','corpus/.venv/bin/python scripts/kenlm_round2.py all','```',
            'Stages: train, o4a, vocabulary, evaluate, performance, control, report. Source splits are read-only; all new artifacts live under .build/kenlm-round2/. Commands, headers, raw query metrics, cache-purge errors, vocabulary counts and the plot are retained there.',
            '','![Second-round size versus perplexity](.build/kenlm-round2/size_vs_ppl.png)','', 'Final combined-data retraining remains unperformed.']
    text='\n'.join(lines)+'\n';(out/'report.md').write_text(text.replace('(.build/kenlm-round2/','('))
    readme=ROOT/'README_kenlm_train.md';begin='<!-- KENLM_ROUND2_BEGIN -->';end='<!-- KENLM_ROUND2_END -->';s=readme.read_text()
    if begin in s:
        pre,rest=s.split(begin,1);_,post=rest.split(end,1);s=pre+begin+'\n'+text+end+post
    else:s+='\n'+begin+'\n'+text+end+'\n'
    readme.write_text(s)
    save(out/'summary.json',{'models':rows,'runtime':perf,'vocabulary':vocab,'final_combined_data_training':False})
    fig,ax=plt.subplots(figsize=(11,7));offsets=[(7,7),(7,7),(7,7),(7,-14),(7,-14),(7,9),(7,9),(7,-14),(7,7)]
    for r,offset in zip(rows,offsets):
        unq=r['configuration']=='o4a-unquantized';ax.scatter(r['binary_bytes']/1048576,r['perplexity_including_oovs'],marker='D' if unq else 'o',s=70,color='#d97706' if unq else '#2563eb',zorder=3)
        ax.annotate(r['configuration'],(r['binary_bytes']/1048576,r['perplexity_including_oovs']),xytext=offset,textcoords='offset points',fontsize=10)
    ax.set(xlabel='Trie binary size (MiB)',ylabel='Heldout perplexity including OOVs',title='KenLM round 2: size versus heldout perplexity')
    ax.grid(alpha=.22);ax.margins(.14);fig.text(.12,.025,'Same frozen train/heldout splits; blue: 8-bit probability/backoff trie; orange: unquantized o4a.',fontsize=10)
    fig.tight_layout(rect=(0,.04,1,1));fig.savefig(out/'size_vs_ppl.png',dpi=200);plt.close(fig)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('stage',choices=('all','train','o4a','vocabulary','evaluate','performance','report','control'));p.add_argument('--output',type=Path,default=OUT);args=p.parse_args();out=args.output;out.mkdir(parents=True,exist_ok=True)
    os.environ['MPLCONFIGDIR']=str(out/'mpl-cache')
    pin_inputs(out)
    stages={'train':train_all,'o4a':o4a_extra,'vocabulary':vocabulary,'evaluate':eval_all,'performance':performance,'control':quantization_control,'report':report}
    for name,fn in stages.items():
        if args.stage in ('all',name):fn(out)
    pin_inputs(out)

if __name__=='__main__':main()
