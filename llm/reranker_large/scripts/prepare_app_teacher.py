"""Freeze native App pools and cache matched Qwen conditional/BOS adjustments."""
import argparse
from collections import Counter
import copy
import fcntl
import json
import math
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time
import tomllib

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))
from corpus.common import new_directory
from llm.pinyin_to_text.common import file_hash, fingerprint, normalized, read_json, write_json
from llm.reranker_small.data import load_bundle
from llm.reranker_large.app_scoring import bonus_values, pool_bonus_values
from llm.reranker_large.data import PoolWriter, Pools, checked_file, load_pools, manifest_at
from llm.reranker_large.prepare import finish_manifest
from llm.reranker_large.scoring import printable, suffix, validate_pool
from llm.reranker_large.settings import APP_PROTOCOL, ROOT, SPLITS, code_identity, load_config, score_mapping
from llm.reranker_large.teacher import PROTOCOL, QwenTeacher
from llm.reranker_large.scripts.distillation_data import unescape


def log(stage, **values):
    print(json.dumps(dict(stage=stage, **values), ensure_ascii=False), flush=True)


class NativePools:
    def __init__(self, work):
        self.child = subprocess.Popen([str(work/'si-cli'), '--config', str(work/'si.conf'),
            'candidates', str(work/'main.silex'), '--grams', str(work/'words.sigram'),
            '--languages', 'zh-Hans,en', '--pinyin-correction', 'on', '--search', 'full',
            '--request-format', 'context-tsv', '--output-format', 'model-tsv'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding='utf-8', bufsize=1)

    def query(self, spelling, context):
        if any(c in spelling+context for c in '\t\r\n'):
            raise ValueError('Native pool request cannot contain TSV control characters')
        self.child.stdin.write(spelling+'\t'+context+'\n')
        self.child.stdin.flush()
        first = self.child.stdout.readline()
        if not first.startswith('context\t'):
            raise RuntimeError('Native pool export failed; rebuild Release si-cli')
        fragment = unescape(first.rstrip('\n').split('\t', 1)[1])
        candidates, scores, mask, adjustment_mask = [], [], [], []
        while True:
            line = self.child.stdout.readline()
            if not line:
                raise RuntimeError('Native pool exporter exited')
            if line == '\n':
                return fragment, candidates, scores, mask, adjustment_mask
            selected, adjusted, base, language, consumed, kind, lexical, text = line.rstrip('\n').split('\t', 7)
            candidates.append(dict(text=unescape(text), language=language))
            scores.append(float(base))
            mask.append(selected == '1')
            adjustment_mask.append(adjusted == '1')

    def close(self):
        self.child.stdin.close()
        self.child.stdout.close()
        if self.child.wait(timeout=10):
            raise RuntimeError('Native pool export failed')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=ROOT/'configs/distill-app-v4.json')
    p.add_argument('--data', type=Path, default=ROOT/'data/prepared/student-15m-v1/lm')
    p.add_argument('--source', type=Path, default=ROOT/'data/prepared/student-15m-v1/teacher-pilot')
    p.add_argument('--output', type=Path, default=ROOT/'data/prepared/student-15m-v1/teacher-app-v4')
    p.add_argument('--likelihood-cache', type=Path,
                   help='Verified App cache with the same Qwen raw conditional/BOS likelihoods')
    p.add_argument('--model', type=Path, default=REPO/'.build/models/Qwen2.5-0.5B')
    p.add_argument('--binary', type=Path, default=REPO/'target/release/si-cli')
    p.add_argument('--lexicon', type=Path, default=REPO/'Data/Engine/main.silex')
    p.add_argument('--grams', type=Path, default=REPO/'Data/Engine/words.sigram')
    p.add_argument('--engine-config', type=Path, default=REPO/'config/si.conf')
    p.add_argument('--device', choices=('mps', 'cpu', 'cuda'), default='mps')
    p.add_argument('--threads', type=int, default=4)
    p.add_argument('--resume', action='store_true')
    args = p.parse_args()
    config = load_config(args.config)
    if config['scoring'].get('protocol') != APP_PROTOCOL:
        raise ValueError('Select the App-aligned configuration')
    legacy = copy.deepcopy(config)
    legacy['scoring'].pop('protocol')
    legacy['scoring'].pop('app')
    lm, tokenizer, _ = load_bundle(args.data, config, ('train',))
    source, datasets = load_pools(args.source, legacy, lm, tokenizer, SPLITS, scored=True)
    if source['teacher']['protocol'] != PROTOCOL:
        raise ValueError('Only the frozen conditional-sum teacher cache can be upgraded')
    for name in source['files']:
        checked_file(args.source, source, name)
    model_files = {p.name: file_hash(p) for p in sorted(args.model.iterdir()) if p.is_file()}
    if model_files != source['teacher']['files']:
        raise ValueError('The Qwen snapshot differs from the original score cache')
    borrowed = None
    if args.likelihood_cache:
        borrowed = manifest_at(args.likelihood_cache, 'si-student-pools')
        raw_identity = {k:v for k,v in borrowed['teacher'].items()
                        if k not in ('protocol','sequence_protocol','score_mapping')}
        original_identity = {k:v for k,v in source['teacher'].items() if k != 'protocol'}
        if (raw_identity != original_identity or borrowed['teacher'].get('sequence_protocol') != PROTOCOL
                or borrowed.get('parent_pool_dataset_id') != source['dataset_id']
                or borrowed['tokenizer_digest'] != tokenizer.digest or borrowed['limits'] != source['limits']
                or borrowed.get('scored_splits') != ['train','validation']):
            raise ValueError('Likelihood cache model/runtime, parent, tokenizer or protocol differs')
        for name in borrowed['files']:
            checked_file(args.likelihood_cache, borrowed, name)
    resources = {name: dict(sha256=file_hash(getattr(args, attr)), bytes=getattr(args, attr).stat().st_size)
                 for name, attr in (('si-cli', 'binary'), ('main.silex', 'lexicon'), ('words.sigram', 'grams'), ('si.conf', 'engine_config'))}
    identity = dict(source_dataset_id=source['dataset_id'], lm_dataset_id=lm['dataset_id'],
                    config=config, resources=resources, model_files=model_files, device=args.device, threads=args.threads,
                    code_identity=code_identity(), producer_sha256=file_hash(Path(__file__)),
                    likelihood_cache_dataset_id=borrowed['dataset_id'] if borrowed else None)
    work = args.output.resolve().with_name('.'+args.output.name+'.work')
    if args.output.exists():
        raise FileExistsError('Select a new output; caches are immutable')
    if work.exists():
        if not args.resume or read_json(work/'identity.json') != identity:
            raise ValueError('Resume requires identical inputs/code/config/model/device')
    else:
        if args.resume:
            raise ValueError('No preparation work exists')
        work.mkdir(parents=True)
        write_json(work/'identity.json', identity)
    with (work/'writer.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name, attr in (('si-cli', 'binary'), ('main.silex', 'lexicon'), ('words.sigram', 'grams'), ('si.conf', 'engine_config')):
            target = work/name
            if not target.exists():
                shutil.copyfile(getattr(args, attr), target)
            if file_hash(target) != resources[name]['sha256']:
                raise ValueError('Engine snapshot changed: '+name)
        (work/'si-cli').chmod(0o700)
        native_config = tomllib.loads((work/'si.conf').read_text())['local_model_ranking']
        for key, value in config['scoring']['app'].items():
            if native_config[key] != value:
                raise ValueError('App parameter mismatch: '+key)
        for local, native in (('max_candidates','model_candidate_limit'), ('context_tokens','model_context_token_limit'),
                              ('candidate_tokens','model_candidate_token_limit')):
            if config['scoring'][local] != native_config[native]:
                raise ValueError('App bound mismatch: '+local)
        db = sqlite3.connect(work/'cache.sqlite3')
        db.executescript('CREATE TABLE IF NOT EXISTS rows(id TEXT PRIMARY KEY, split TEXT, payload TEXT, scored INTEGER);'
                         'CREATE TABLE IF NOT EXISTS likelihood(context TEXT,text TEXT,value REAL,PRIMARY KEY(context,text));'
                         'CREATE TABLE IF NOT EXISTS queries(query TEXT PRIMARY KEY,id TEXT,split TEXT);'
                         'CREATE TABLE IF NOT EXISTS excluded(id TEXT PRIMARY KEY,reason TEXT);')
        if borrowed and not (work/'likelihoods-imported.json').exists():
            imported = 0
            for split in ('train','validation'):
                cache_rows = Pools(args.likelihood_cache, borrowed, split)
                for i in range(len(cache_rows)):
                    row = cache_rows[i]
                    # Borrow only likelihoods; an older cache has no fallback mask.
                    checked = {**row, 'model_adjustment_mask':row.get('model_adjustment_mask', row['model_mask'])}
                    if not validate_pool(checked, tokenizer, config):
                        raise ValueError('Invalid borrowed likelihood row')
                    for candidate, flag, conditional, baseline in zip(row['candidates'], row['model_mask'],
                            row['teacher_conditional_logp'], row['teacher_baseline_logp'], strict=True):
                        if flag:
                            db.execute('INSERT OR IGNORE INTO likelihood VALUES (?,?,?)', ('',candidate['text'],baseline))
                            db.execute('INSERT OR IGNORE INTO likelihood VALUES (?,?,?)', (row['context'],candidate['text'],conditional))
                            imported += 2
                db.commit()
            write_json(work/'likelihoods-imported.json',dict(dataset_id=borrowed['dataset_id'],values=imported))
            log('likelihood-cache-imported',dataset_id=borrowed['dataset_id'],values=imported)
        if not (work/'pools-ready.json').exists():
            native = NativePools(work)
            counts = Counter()
            last_log = time.monotonic()
            try:
                for split in ('test','validation','train'):
                    for i in range(len(datasets[split])):
                        old = datasets[split][i]
                        if db.execute('SELECT 1 FROM rows WHERE id=? UNION SELECT 1 FROM excluded WHERE id=?', (old['id'],old['id'])).fetchone():
                            continue
                        field = old['context']
                        fragment, candidates, bases, mask, adjustment_mask = native.query(old['input'], field)
                        context = suffix(fragment, tokenizer, config['scoring']['context_tokens'])
                        if len({c['text'] for c, flag in zip(candidates, mask) if flag}) < 2 or any(
                            flag and len(tokenizer.encode(c['text']))-2 > config['scoring']['candidate_tokens']
                            for c, flag in zip(candidates, mask)):
                            mask = [False]*len(candidates)
                        row = {k:v for k,v in old.items() if k not in ('teacher_scores','reference_indices','labels_reviewed')}
                        row.update(context=context, field_context=field, candidates=candidates,
                                   base_scores_bits=bases, model_mask=mask, model_adjustment_mask=adjustment_mask,
                                   observed_in_pool=any(c['text']==old['observed_text'] for c in candidates))
                        used=len(tokenizer.encode(context))-2
                        row['case']={**row['case'],'context':('none' if not used else 'short' if used<=4 else 'medium' if used<=8 else 'long')}
                        if not 2<=len(candidates)<=8192 or any(not printable(c['text']) for c in candidates) or any(not math.isfinite(s) for s in bases):
                            db.execute('INSERT INTO excluded VALUES (?,?)',(old['id'],'fewer-than-two-or-invalid-whole-candidates'))
                        elif not validate_pool(row, tokenizer, config):
                            db.execute('INSERT INTO excluded VALUES (?,?)',(old['id'],'observed-or-model-token-limit'))
                        else:
                            query=fingerprint([normalized(context),normalized(row['input']),
                                sorted((normalized(c['text']),c['language']) for c in candidates)])
                            previous=db.execute('SELECT split FROM queries WHERE query=?',(query,)).fetchone()
                            if previous:
                                db.execute('INSERT INTO excluded VALUES (?,?)',(old['id'],'duplicate-app-query' if previous[0]==split else 'cross-split-app-query'))
                            else:
                                db.execute('INSERT INTO queries VALUES (?,?,?)',(query,row['id'],split))
                                db.execute('INSERT INTO rows VALUES (?,?,?,0)',(row['id'],split,json.dumps(row,ensure_ascii=False)))
                                counts[split] += 1
                        if 'teacher_scores' in old:
                            db.executemany('INSERT OR IGNORE INTO likelihood VALUES (?,?,?)',
                                ((old['context'], c['text'], v) for c,v in zip(old['candidates'],old['teacher_scores'],strict=True)))
                        db.commit()
                        if time.monotonic()-last_log >= 10:
                            log('native-pools', split=split, processed=i+1, total=len(datasets[split]), accepted=dict(counts))
                            last_log=time.monotonic()
            finally:
                native.close()
            write_json(work/'pools-ready.json',dict(ready=True))
        teacher = None
        hits, generated = 0, 0
        def likelihoods(context, texts):
            nonlocal teacher, hits, generated
            values, missing = {}, []
            for text in texts:
                found=db.execute('SELECT value FROM likelihood WHERE context=? AND text=?',(context,text)).fetchone()
                if found: values[text]=found[0]; hits+=1
                else: missing.append(text)
            if missing:
                if teacher is None:
                    teacher=QwenTeacher(args.model,args.device,args.threads)
                    if teacher.identity != source['teacher']:
                        raise ValueError('Teacher runtime identity differs; score into a fresh nonreused cache')
                    log('qwen-loaded', device=args.device)
                for offset in range(0,len(missing),12):
                    batch=missing[offset:offset+12]
                    scores=teacher.sequence_scores(context,batch)
                    for text,value in zip(batch,scores,strict=True):
                        values[text]=value
                        db.execute('INSERT INTO likelihood VALUES (?,?,?)',(context,text,value))
                        generated+=1
            return values
        last_log=time.monotonic()
        for split in ('train','validation'):
            remaining=list(db.execute('SELECT id,payload FROM rows WHERE split=? AND scored=0 ORDER BY id',(split,)))
            for i,(identity_row,payload) in enumerate(remaining):
                row=json.loads(payload)
                texts=list(dict.fromkeys(c['text'] for c,f in zip(row['candidates'],row['model_mask']) if f))
                base=likelihoods('',texts)
                cond=likelihoods(row['context'],texts) if row['context'] else base
                bonuses=bonus_values([cond[t] for t in texts],[base[t] for t in texts],texts,bool(row['context']),config['scoring']['app']) if texts else []
                row['teacher_baseline_logp']=[base[c['text']] if f else None for c,f in zip(row['candidates'],row['model_mask'])]
                row['teacher_conditional_logp']=[cond[c['text']] if f else None for c,f in zip(row['candidates'],row['model_mask'])]
                adjustments=pool_bonus_values(row['candidates'],row['model_adjustment_mask'],texts,bonuses)
                row['teacher_scores']=[b+adjustment for b,adjustment in zip(row['base_scores_bits'],adjustments,strict=True)]
                assert validate_pool(row,tokenizer,config)
                db.execute('UPDATE rows SET payload=?,scored=1 WHERE id=?',(json.dumps(row,ensure_ascii=False),identity_row))
                db.commit()
                if time.monotonic()-last_log>=10:
                    log('teacher-scoring',split=split,processed=i+1,pending_at_start=len(remaining),cache_hits=hits,new_likelihoods=generated)
                    last_log=time.monotonic()
        if teacher: teacher.verify()
        else:
            if model_files!={p.name:file_hash(p) for p in args.model.iterdir() if p.is_file()}:
                raise ValueError('Teacher files changed')
        stats={}
        with new_directory(args.output) as staged:
            for name in source['files']:
                if name in ('NOTICE.md','source-lock.json') or name.startswith('metadata/'):
                    source_path=checked_file(args.source,source,name)
                    target=staged/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source_path,target)
            metadata=staged/'metadata/app-alignment';metadata.mkdir(parents=True)
            write_json(metadata/'identity.json',identity)
            shutil.copyfile(work/'si.conf',metadata/'si.conf')
            shutil.copyfile(__file__,metadata/'producer.py')
            if borrowed:
                shutil.copyfile(args.likelihood_cache/'manifest.json',metadata/'likelihood-cache-manifest.json')
            original=read_json(staged/'source-lock.json')
            original['app_alignment']=identity
            write_json(staged/'source-lock.json',original)
            with (staged/'NOTICE.md').open('a') as stream:
                stream.write('\nApp-aligned derivative: native statistical scores, model selection mask and '
                    'punctuation fragments use the frozen engine/config identity in metadata/app-alignment/. '
                    'Teacher and student use the same bit-valued bounded adjustments before statistical fusion.\n')
            for split in SPLITS:
                writer=PoolWriter(staged,split);counts=Counter()
                try:
                    for (payload,) in db.execute('SELECT payload FROM rows WHERE split=? ORDER BY id',(split,)):
                        row=json.loads(payload)
                        if split=='test': assert 'teacher_scores' not in row
                        assert validate_pool(row,tokenizer,config)
                        writer.append(row)
                        counts.update(pools=1,model_active=bool(any(row['model_mask'])),model_candidates=sum(row['model_mask']),
                                      whole_candidates=len(row['candidates']),observed_in_pool=row['observed_in_pool'])
                        counts['contextual' if row['context'] else 'bos_only']+=1
                finally:writer.close()
                if not writer.count:raise ValueError('An aligned split is empty')
                stats[split]=dict(counts)
            write_json(metadata/'report.json',dict(splits=stats,excluded=dict(db.execute('SELECT reason,COUNT(*) FROM excluded GROUP BY reason')),
                note='Full whole-input nonliteral pools with empty personal profile. Only native selected model rows require inference; eligible unscored whole rows inherit the pool minimum, while matching texts reuse their actual adjustment. Test is not teacher-scored.'))
            mapped_identity={**source['teacher'],'protocol':APP_PROTOCOL,'sequence_protocol':PROTOCOL,'score_mapping':score_mapping(config)}
            result=finish_manifest(staged,dict(schema_version=1,kind='si-student-pools',lm_dataset_id=lm['dataset_id'],
                tokenizer_digest=tokenizer.digest,limits=source['limits'],score_mapping=score_mapping(config),
                splits={s:{'pools':stats[s]['pools']} for s in SPLITS},teacher=mapped_identity,
                parent_pool_dataset_id=source['dataset_id'],scored_splits=['train','validation'],generation=identity))
        db.close()
        log('complete',output=str(args.output),dataset_id=result['dataset_id'],splits=stats)


if __name__=='__main__':main()
