"""Mine new contrast cases and seal score-blind validation without model inference."""
import argparse
import csv
from collections import Counter,defaultdict
from difflib import SequenceMatcher
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import sqlite3
import sys
import time

REPO=Path(__file__).resolve().parents[3];sys.path.insert(0,str(REPO))
from corpus.common import new_directory
from llm.pinyin_to_text.common import file_hash,fingerprint,normalized,read_json,read_jsonl,write_json
from llm.reranker_large.data import checked_file,manifest_at
from llm.reranker_large.prepare import finish_manifest
from llm.reranker_large.scoring import suffix
from llm.reranker_large.scripts.distillation_data import DictionaryReadings,template
from llm.reranker_small.tokenizer import Tokenizer

ROOT=REPO/'llm/reranker_large'
HAN=re.compile(r'^[\u3400-\u9fff]+$')
SOURCE_WEIGHTS={'public_dialogue':.35,'si_dialogues':.35,'wikipedia':.20,'si_workbuddy':.05,'technical':.05}


def compact(text):
    return re.sub(r'[^\w\u3400-\u9fff]','',normalized(text))


def shingles(text):
    text=compact(text)
    return {text[i:i+3] for i in range(max(0,len(text)-2))}


class ExclusionGuard:
    """Deterministic lexical near-duplicate checks; not semantic certification."""
    def __init__(self,rows):
        self.queries=set();self.long_targets=set();self.contexts=defaultdict(list)
        self.examples=[];self.index=defaultdict(set)
        for row in rows:
            spelling=normalized(row['input']).replace("'",'')
            context=compact(row.get('context',''))
            self.queries.add((spelling,context))
            if len(context)>=6:self.contexts[spelling].append((context,shingles(context)))
            for target in row.get('references',[]):
                if len(compact(target))>=4:self.long_targets.add(compact(target))
                full=compact(row.get('context','')+target)
                if len(full)>=8:
                    index=len(self.examples);grams=shingles(full)
                    self.examples.append((full,grams))
                    for gram in grams:self.index[gram].add(index)

    def reason(self,spelling,context,texts):
        spelling=normalized(spelling).replace("'",'');context=compact(context)
        if (spelling,context) in self.queries:return 'exact_legacy_query'
        if len(context)>=6:
            grams=shingles(context)
            for old,previous in self.contexts[spelling]:
                if min(len(context),len(old))/max(len(context),len(old))>=.7 and len(grams&previous)/len(grams|previous)>=.65:
                    return 'near_legacy_context'
        for text in texts:
            full=compact(context+text);grams=shingles(full)
            if any(t in full for t in self.long_targets):return 'legacy_full_target'
            if len(full)<8:continue
            possible=set()
            for gram in grams:possible.update(self.index.get(gram,()))
            for index in possible:
                old,previous=self.examples[index]
                if min(len(full),len(old))/max(len(full),len(old))>=.7 and len(grams&previous)/len(grams|previous)>=.70:
                    return 'near_legacy_text'
        return None


def walk_cases(value):
    if isinstance(value,dict):
        if isinstance(value.get('input'),str) and isinstance(value.get('references'),list):
            yield value
        else:
            for item in value.values():yield from walk_cases(item)
    elif isinstance(value,list):
        for item in value:yield from walk_cases(item)


def legacy_cases():
    rows=[];pins={}
    for name in ('eval/ranking/context.jsonl','eval/ranking/context-free.jsonl','eval/recall/test.jsonl','eval/ranking/review-20261126.json'):
        path=REPO/name;pins[name]=file_hash(path)
        if path.suffix=='.jsonl':rows.extend(read_jsonl(path))
        else:rows.extend(walk_cases(read_json(path)))
    return rows,pins


def patterns_at(overlap,readings):
    pairs={};origins=defaultdict(set)
    for scope,values in overlap['scopes'].items():
        if not scope.startswith('native-whole-fusion/'):continue
        for rows in values['regression_cases'].values():
            for row in rows:
                for reference in row['references']:
                    wrong=row['distilled']['prediction']
                    choices=[]
                    if 1<=len(reference)<=3 and 1<=len(wrong)<=3:choices.append((reference,wrong))
                    for tag,a,b,c,d in SequenceMatcher(None,reference,wrong,autojunk=False).get_opcodes():
                        if tag=='replace':choices.append((reference[a:b],wrong[c:d]))
                    for good,bad in choices:
                        if not (1<=len(good)<=3 and 1<=len(bad)<=3 and good!=bad and HAN.fullmatch(good) and HAN.fullmatch(bad)):continue
                        left=readings.options(good) if hasattr(readings,'options') else {readings.encode(good)}
                        right=readings.options(bad) if hasattr(readings,'options') else {readings.encode(bad)}
                        common=(left&right)-{None,''}
                        if len(common)!=1:continue
                        spelling=next(iter(common))
                        variants=tuple(sorted((good,bad)));key=(spelling,variants)
                        pairs[key]=dict(id='pattern-'+fingerprint(key)[:16],spelling=spelling,variants=list(variants),
                                        kind='contextual-single-scalar' if max(map(len,variants))==1 else 'short-homophone-word')
                        origins[key].add(row['id'])
    return [{**value,'diagnostic_origin_ids':sorted(origins[key])} for key,value in sorted(pairs.items())]


class FocusReadings(DictionaryReadings):
    """Keep declared alternate readings for short, explicitly contrasted spans."""
    def __init__(self,db,overlap):
        super().__init__(db)
        needed=set()
        for scope,values in overlap['scopes'].items():
            if not scope.startswith('native-whole-fusion/'):continue
            for rows in values['regression_cases'].values():
                for row in rows:
                    for text in [*row['references'],row['distilled']['prediction']]:
                        for i in range(len(text)):
                            for n in range(1,4):needed.add(text[i:i+n])
        self.alternatives=defaultdict(set)
        for path in sorted((REPO/'Data/Chinese').glob('*.csv')):
            for row in csv.DictReader(path.open(encoding='utf-8-sig')):
                if row['text'] in needed:
                    self.alternatives[row['text']].add(row['reading'].replace("'",'').replace('ü','v'))

    def options(self,text):
        value=self.encode(text)
        return ({value} if value else set()) | self.alternatives.get(text,set())


def contrast_spelling(readings,observed,negative,before,after,spelling):
    left,right=readings.encode(observed),readings.encode(negative)
    if left and left==right:return left
    prefix,suffix_value=readings.encode(before),readings.encode(after)
    if prefix is None or suffix_value is None:return None
    proposed=prefix+spelling+suffix_value
    # Do not override a known longer lexical reading with a character guess.
    if (left is not None and left!=proposed) or (right is not None and right!=proposed):return None
    return proposed


def ordered_candidates(texts,key):
    return [dict(text=text,language='zh-Hans') for text in sorted(set(texts),key=lambda t:fingerprint([key,t]))]


def build_validation(seeds,readings,tokenizer,guard,old_inputs):
    rows=[];stats=Counter();reserved_words=set();reserved_spellings=set();seen=set()
    family_ids=set()
    for family in seeds['families']:
        if family['id'] in family_ids or family['spelling'] in reserved_spellings:
            raise ValueError('Independent validation repeats a lexical family')
        family_ids.add(family['id'])
        variants=[v['text'] for v in family['variants']]
        if len(set(variants))!=2:raise ValueError('Validation families require two distinct contrasts')
        if family['spelling'] in old_inputs:raise ValueError('Validation confusion family appears in prior ranking/distillation: '+family['id'])
        if any(readings.encode(t)!=family['spelling'] for t in variants):raise ValueError('Validation reading mismatch: '+family['id'])
        reserved_words.update(variants);reserved_spellings.add(family['spelling'])
        for variant in family['variants']:
            for index,(prefix,postfix) in enumerate(variant['frames']):
                word=variant['text'];sentence=prefix+word+postfix
                if any(t in prefix+postfix for t in variants):raise ValueError('Target text leaks into validation cue: '+family['id'])
                for mode in ('contextual','context-free'):
                    context=suffix(prefix,tokenizer,16) if mode=='contextual' else ''
                    observed=word if mode=='contextual' else sentence
                    choices=variants if mode=='contextual' else [prefix+t+postfix for t in variants]
                    spelling=readings.encode(observed)
                    if not spelling or any(readings.encode(t)!=spelling for t in choices):
                        stats['excluded_ambiguous_reading']+=1;continue
                    if any(len(tokenizer.encode(t))-2>16 for t in choices):stats['excluded_token_limit']+=1;continue
                    reason=guard.reason(spelling,context,choices)
                    if reason:raise ValueError('Independent validation overlaps legacy fixture: '+family['id']+'/'+reason)
                    query=(normalized(spelling),normalized(context),tuple(sorted(choices)))
                    if query in seen:raise ValueError('Independent validation repeats a query')
                    seen.add(query)
                    identity=fingerprint(['coverage-independent-v1',family['id'],word,index,mode])
                    rows.append(dict(id='independent-'+identity[:24],split='independent_validation',family_id=family['id'],
                        template_group=family['id'],mode=mode,input=spelling,context=context,observed_text=observed,
                        candidates=ordered_candidates(choices,family['id']+mode+str(index)),intended_text=observed,
                        label_status='ai-authored-intention-unreviewed',human_reviewed=False,
                        origin=dict(seed_family=family['id'],variant=word,frame=index),
                        note='No teacher/student output was inspected; intended answer is synthetic and needs independent review.'))
                    stats[mode]+=1
    if len(rows)<128:raise ValueError('Too few independently authored validation cases')
    return rows,dict(stats),reserved_words,reserved_spellings


def contexts_before(text,start):
    # Do not join turns or cross the preceding punctuation-delimited fragment.
    value=text[max(0,start-128):start]
    return re.split(r'[。！？!?；;，,：:\n\r\t]',value)[-1]


def mine(db,patterns,tokenizer,guard,reserved_words,reserved_spellings,old_doc_ids,old_groups,
         old_queries,limit,per_pattern,scan_limit,seed):
    anchors=defaultdict(list)
    for pattern in patterns:
        for good in pattern['variants']:
            bad=next(t for t in pattern['variants'] if t!=good)
            anchors[good].append((pattern,bad))
    expression=re.compile('|'.join(map(re.escape,sorted(anchors,key=lambda x:(-len(x),x)))))
    readings=DictionaryReadings(db);rows=[];documents={};stats=Counter();by_pattern=Counter();by_source=Counter();seen=set()
    last=time.monotonic()
    for source,share in SOURCE_WEIGHTS.items():
        quota=max(1,round(limit*share));scanned=0
        cursor=db.execute("SELECT id,source,split,text,origin,grp,file_key FROM docs WHERE split='train' AND source=? ORDER BY file_key,priority LIMIT ?",(source,scan_limit))
        for raw in cursor:
            scanned+=1;stats['documents_scanned']+=1
            doc=dict(zip(('id','source','split','text','origin','grp','file_key'),raw))
            if by_source[source]>=quota:break
            if doc['id'] in old_doc_ids or doc['grp'] in old_groups:stats['old_source_group_excluded']+=1;continue
            matches=list(expression.finditer(doc['text']))
            if not matches:continue
            rng=random.Random(fingerprint([seed,doc['id']]))
            rng.shuffle(matches);from_doc=0
            for match in matches:
                good=match[0];start,end=match.span()
                options=list(anchors[good]);rng.shuffle(options)
                for pattern,bad in options:
                    if by_pattern[pattern['id']]>=per_pattern:continue
                    for mode in ('contextual','context-free'):
                        if from_doc>=2 or by_source[source]>=quota or len(rows)>=limit or by_pattern[pattern['id']]>=per_pattern:break
                        if mode=='contextual':
                            before=contexts_before(doc['text'],start);context=suffix(before,tokenizer,16)
                            if len(tokenizer.encode(context))-2<2:stats['empty_context_excluded']+=1;continue
                            observed=good;negative=bad;span_start,span_end=start,end
                            left_piece=right_piece=''
                        else:
                            # A natural sentence window, not a rewrite of a regression fixture.
                            span_start=max(0,start-rng.randint(2,5));span_end=min(len(doc['text']),end+rng.randint(2,5))
                            observed=doc['text'][span_start:span_end]
                            if not 4<=len(observed)<=16 or not HAN.fullmatch(observed):continue
                            negative=observed[:start-span_start]+bad+observed[end-span_start:];context=''
                            left_piece=observed[:start-span_start];right_piece=observed[end-span_start:]
                        choices=(observed,negative)
                        if any(t in context+''.join(choices) for t in reserved_words):stats['heldout_lexeme_excluded']+=1;continue
                        spelling=contrast_spelling(readings,observed,negative,left_piece,right_piece,pattern['spelling'])
                        if not spelling:stats['ambiguous_reading_excluded']+=1;continue
                        if spelling in reserved_spellings:stats['heldout_family_excluded']+=1;continue
                        if any(len(tokenizer.encode(t))-2>16 for t in choices):stats['token_limit_excluded']+=1;continue
                        reason=guard.reason(spelling,context,choices)
                        if reason:stats[reason]+=1;continue
                        query=(normalized(spelling),normalized(context))
                        if query in seen or query in old_queries:stats['duplicate_or_prior_query_excluded']+=1;continue
                        seen.add(query)
                        identity=fingerprint(['coverage-train-v1',doc['id'],span_start,span_end,context,pattern['id']])
                        row=dict(id='coverage-'+identity[:24],split='train',pattern_id=pattern['id'],pattern_kind=pattern['kind'],
                            mode=mode,input=spelling,context=context,observed_text=observed,
                            candidates=ordered_candidates(choices,identity),label_status='natural-source-span-not-ranking-gold',
                            source=source,document_id=doc['id'],source_group=doc['grp'],origin=doc['origin'],
                            span_start=span_start,span_end=span_end,focus_start=start,focus_end=end,
                            focus_spelling=pattern['spelling'],reading_origin='paired-maintained-lexicon-readings',
                            pool_origin='explicit-same-spelling-training-contrast',teacher_scored=False)
                        rows.append(row);documents[doc['id']]=doc;from_doc+=1
                        by_pattern[pattern['id']]+=1;by_source[source]+=1;stats[mode]+=1
                if from_doc>=2:break
            if time.monotonic()-last>=15:
                print(json.dumps(dict(stage='coverage-mining',source=source,scanned=stats['documents_scanned'],accepted=len(rows))),flush=True);last=time.monotonic()
        stats['scanned:'+source]=scanned
    return rows,documents,dict(stats),dict(by_pattern),dict(by_source)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--index',type=Path,default=ROOT/'data/prepared/student-15m-v1/.pools-pilot.work/work.sqlite3')
    parser.add_argument('--parent',type=Path,default=ROOT/'data/prepared/student-15m-v1/teacher-app-v4-sequence-kd-v1')
    parser.add_argument('--overlap',type=Path,default=REPO/'eval/reports/sequence-kd-v1-20261127/teacher-overlap.json')
    parser.add_argument('--validation-seeds',type=Path,default=ROOT/'data/coverage/independent-families-v1.json')
    parser.add_argument('--output',type=Path,default=ROOT/'data/prepared/student-15m-v1/coverage-v1')
    parser.add_argument('--limit',type=int,default=6000)
    parser.add_argument('--per-pattern',type=int,default=160)
    parser.add_argument('--scan-per-source',type=int,default=100000)
    parser.add_argument('--seed',type=int,default=20261127)
    args=parser.parse_args()
    if min(args.limit,args.per_pattern,args.scan_per_source)<=0:raise ValueError('Positive mining budgets required')
    if args.output.exists():raise FileExistsError('Use a fresh immutable coverage output')
    parent=manifest_at(args.parent,'si-student-pools')
    for name in parent['files']:checked_file(args.parent,parent,name)
    legacy,legacy_pins=legacy_cases();guard=ExclusionGuard(legacy)
    old_inputs={normalized(row['input']).replace("'",'') for row in legacy};old_queries=set();old_doc_ids=set();old_groups=set()
    previous=[args.parent]
    for name in ('teacher-pilot','teacher-app-v4'):
        path=args.parent.parent/name
        if path!=args.parent and path.exists():previous.append(path)
    previous_pins={}
    for path in previous:
        previous_manifest=manifest_at(path,'si-student-pools')
        previous_pins[path.name]=previous_manifest['dataset_id']
        for split in ('train','validation','test'):
            checked_file(path,previous_manifest,split+'.jsonl')
            for row in read_jsonl(path/(split+'.jsonl')):
                old_inputs.add(normalized(row['input']).replace("'",''));old_queries.add((normalized(row['input']),normalized(row['context'])))
                old_doc_ids.add(row['document_id']);old_groups.add(row['source_group'])
    db=sqlite3.connect('file:'+str(args.index.resolve())+'?mode=ro',uri=True)
    try:
        db.execute('PRAGMA query_only=ON');diagnostic=read_json(args.overlap);readings=FocusReadings(db,diagnostic)
        tokenizer=Tokenizer.load(ROOT/'data/prepared/student-15m-v1/lm/tokenizer.json')
        patterns=patterns_at(diagnostic,readings)
        if len(patterns)<20:raise ValueError('Insufficient dictionary-verified regression pattern families')
        seeds=read_json(args.validation_seeds)
        validation,val_stats,reserved_words,reserved_spellings=build_validation(seeds,readings,tokenizer,guard,old_inputs)
        if any(p['spelling'] in reserved_spellings for p in patterns):
            raise ValueError('Training diagnostic patterns intersect held-out validation families')
        # Seal content before mining; neither stage has a model runtime or scores.
        validation_seal=fingerprint(validation)
        corpus_pin=file_hash(args.index)
        train,documents,stats,by_pattern,by_source=mine(db,patterns,tokenizer,guard,reserved_words,reserved_spellings,
            old_doc_ids,old_groups,old_queries,args.limit,args.per_pattern,args.scan_per_source,args.seed)
        if len(train)<500:raise ValueError('Too few clean contrast cases; review the exclusion report and budgets')
        # Source document lookup proves the authored validation is not an exact indexed document.
        existing_val_docs=[]
        for row in validation:
            if db.execute('SELECT 1 FROM docs WHERE id=?',(fingerprint(normalized(row['context']+row['observed_text'])),)).fetchone():existing_val_docs.append(row['id'])
        if existing_val_docs:raise ValueError('Independent validation duplicates an indexed source document')
        if file_hash(args.index)!=corpus_pin:raise ValueError('Read-only source index changed')
        report=dict(train_cases=len(train),independent_validation_cases=len(validation),validation_families=len(seeds['families']),
            validation_stats=val_stats,mining_stats=stats,by_source=by_source,by_pattern=by_pattern,
            uncovered_patterns=[p['id'] for p in patterns if p['id'] not in by_pattern],
            validation_seal=validation_seal,model_inference_calls=0,teacher_score_filtering=False,human_reviewed=False,
            exclusions=dict(legacy_rows=len(legacy),previous_document_ids=len(old_doc_ids),previous_source_groups=len(old_groups),
                            heldout_spellings=sorted(reserved_spellings)),
            limitations=['References in independent validation are newly AI-authored intentions, not independent human gold.',
             'Lexical n-gram and exact/template checks do not certify absence of all semantic paraphrases.',
             'Public/SI source language may already have appeared in pretraining. Distillation query/source groups and heldout lexeme families are excluded; unseen pretraining semantics are not claimed.',
             'Training pools are explicit same-spelling contrasts, not native decoder recall measurements. No teacher scores or training were produced.',
             'Validation was authored without inspecting model outputs; preserve its seal and do not retire cases based on Qwen/student mistakes.'])
        with new_directory(args.output) as staged:
            review=[dict(id=r['id'],family_id=r['family_id'],mode=r['mode'],input=r['input'],context=r['context'],
                         candidates=r['candidates'],proposed_intention=r['intended_text'],review_status='pending',
                         acceptable_texts=[],reviewer=None,note='Review linguistic intent without model predictions; record ambiguous cases instead of removing model failures.')
                    for r in validation]
            for filename,rows in (('train-cases.jsonl',train),('independent-validation.jsonl',validation),
                                  ('validation-review.jsonl',review),('source-documents.jsonl',list(documents.values()))):
                with (staged/filename).open('w') as stream:
                    for row in rows:stream.write(json.dumps(row,ensure_ascii=False,allow_nan=False)+'\n')
            write_json(staged/'patterns.json',dict(families=patterns))
            write_json(staged/'audit.json',report)
            metadata=staged/'metadata';metadata.mkdir()
            shutil.copyfile(args.validation_seeds,metadata/'validation-seeds.json')
            shutil.copyfile(args.overlap,metadata/'diagnostic-overlap.json')
            shutil.copyfile(args.parent/'manifest.json',metadata/'parent-manifest.json')
            shutil.copyfile(args.parent/'source-lock.json',metadata/'source-lock.json')
            shutil.copyfile(args.parent/'NOTICE.md',staged/'NOTICE.md')
            shutil.copyfile(__file__,metadata/'producer.py')
            # Preserve selected-source attribution; artifacts remain local/ignored.
            notices=args.parent/'metadata/pretraining/metadata/attribution'
            if notices.exists():shutil.copytree(notices,metadata/'attribution')
            with (staged/'NOTICE.md').open('a') as stream:stream.write('\nCoverage derivative: new source-linked contrasts plus score-blind AI-authored validation intentions. No human review, private host input, model inference or training. Existing source-specific terms remain in force.\n')
            identity=dict(schema_version=1,kind='si-coverage-cases-v1',seed=args.seed,
                parent_pool_dataset_id=parent['dataset_id'],previous_pool_dataset_ids=previous_pins,tokenizer_digest=tokenizer.digest,
                context_tokens=16,candidate_tokens=16,legacy_fixture_hashes=legacy_pins,
                source_index_sha256=corpus_pin,validation_seed_sha256=file_hash(args.validation_seeds),
                diagnostic_sha256=file_hash(args.overlap),validation_seal=validation_seal,
                reading_source_hashes={str(p.relative_to(REPO)):file_hash(p) for p in sorted((REPO/'Data/Chinese').glob('*.csv'))},
                training_count=len(train),independent_validation_count=len(validation),status='unscored-no-training')
            manifest=finish_manifest(staged,identity)
        print(json.dumps(dict(stage='complete',output=str(args.output),dataset_id=manifest['dataset_id'],**report),ensure_ascii=False),flush=True)
    finally:db.close()


if __name__=='__main__':main()
