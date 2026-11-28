"""Explicit matched no-replay/replay experiments; no installation or networking."""
import argparse
import copy
import json
import math
from pathlib import Path
import re
import shutil
import sys
import time

REPO=Path(__file__).resolve().parents[3];sys.path.insert(0,str(REPO))
import torch
from torch.nn import functional as F
from llm.pinyin_to_text.common import file_hash,fingerprint,read_json,read_jsonl,write_json
from llm.reranker_large.app_scoring import forward_app_pool
from llm.reranker_large.data import checked_file,load_pools,manifest_at
from llm.reranker_large.prepare import finish_manifest
from llm.reranker_large.scoring import suffix
from llm.reranker_large.settings import code_files,code_identity,load_config
from llm.reranker_large.train import load_initialization,pool_loss,validate_distillation
from llm.reranker_large.scripts.replay_support import ReplayStream,replay_budget,eligible_selection,improves_selection
from llm.reranker_small.data import load_bundle
from llm.reranker_small.model import CharacterLM
from llm.reranker_small.runtime import atomic_checkpoint,seed_everything,select_device,validation_loss
from llm.reranker_small.tokenizer import PAD
from llm.reranker_small.train import learning_rate

INITIAL_SHA='d8b62715b60064256cbb3c9c5fc5a9651e395ae3e1c73c22faab2f51ac8e74ba'
LANG={'zh-Hans':0,'en':1,'mixed':2}


def log(event,**values):print(json.dumps(dict(event=event,**values),allow_nan=False),flush=True)


def prepare(repo,experiment,learning_rate_override=None,run_tag=None):
    from llm.reranker_large.scripts.prepare_app_teacher import NativePools
    from corpus.common import new_directory
    large=repo/'llm/reranker_large'
    coverage=large/'data/prepared/student-15m-v1/coverage-v1'
    cm=manifest_at(coverage,'si-coverage-cases-v1')
    for name in cm['files']:checked_file(coverage,cm,name)
    cases=list(read_jsonl(coverage/'independent-validation.jsonl'))
    if fingerprint(cases)!=cm['validation_seal']:raise ValueError('Independent validation seal changed')
    pools=large/'data/prepared/student-15m-v1/teacher-app-v4-sequence-kd-v1'
    pm=manifest_at(pools,'si-student-pools')
    config=load_config(pools/'metadata/sequence-kd/config.json')
    if learning_rate_override is not None:
        if not math.isfinite(learning_rate_override) or learning_rate_override<=0:
            raise ValueError('Learning rate must be finite and positive')
        config['training']['learning_rate']=learning_rate_override
    if run_tag is not None and not re.fullmatch('[a-z0-9]+(?:-[a-z0-9]+)*',run_tag):
        raise ValueError('Run tag must use lowercase alphanumeric components')
    config['training']['validate_every']=50
    config['training']['save_every']=50
    policy=dict(max_lm_increase=.1,patience_checks=6,selection='strict-independent-native-top1-with-lm-gate',
                replay_fraction=.25,ratio_definition='replay targets / (KD target exposures + replay targets)',
                loss_mix='(1-replay_fraction)*mean_pool_loss + replay_fraction*mean_replay_LM_loss',
                label_status='AI-authored intentions; not independent human gold')
    policy['run_names']={arm:stem+('-'+run_tag if run_tag else '')+'-v1'
                         for arm,stem in [('control','distill-replay-control'),('replay','distill-replay25')]}
    policy['learning_rate_override']=learning_rate_override
    paths=dict(lm_data=str(large/'data/prepared/student-15m-v1/lm'),pools=str(pools),coverage=str(coverage),
        init_checkpoint=str(large/'runs/student-15m-extra-v1/snapshots/continued-step-019167/best.pt'),
        init_data=str(large/'data/prepared/student-15m-extra-v1/lm'),repo=str(repo))
    if file_hash(paths['init_checkpoint'])!=INITIAL_SHA:raise ValueError('Initialization archive changed')
    _,tokenizer,_=load_bundle(paths['lm_data'],config,('validation',))
    source=large/'data/prepared/student-15m-v1/.teacher-app-v4.work'
    for name,path in [('si.conf',repo/'config/si.conf'),('main.silex',repo/'Data/Engine/main.silex'),('words.sigram',repo/'Data/Engine/words.sigram')]:
        if file_hash(path)!=file_hash(source/name):raise ValueError('App resources/config changed')
    with new_directory(experiment) as staged:
        native=NativePools(source);rows=[]
        try:
            for case in cases:
                fragment,candidates,bases,mask,adjustment=native.query(case['input'],case['context'])
                context=suffix(fragment,tokenizer,16)
                if len({c['text'] for c,f in zip(candidates,mask) if f})<2 or any(f and len(tokenizer.encode(c['text']))-2>16 for c,f in zip(candidates,mask)):
                    mask=[False]*len(candidates)
                rows.append(dict(id=case['id'],context=context,observed_text=case['observed_text'],
                    candidates=candidates,base_scores_bits=bases,model_mask=mask,model_adjustment_mask=adjustment,
                    intended_text=case['intended_text'],family_id=case['family_id'],mode=case['mode'],
                    input=case['input'],field_context=case['context'],human_reviewed=False))
        finally:native.close()
        with (staged/'independent-native.jsonl').open('w') as stream:
            for row in rows:stream.write(json.dumps(row,ensure_ascii=False)+'\n')
        forbidden=[case['context']+c['text'] for case in cases for c in case['candidates']]
        for name in ('context.jsonl','context-free.jsonl'):
            for case in read_jsonl(repo/'eval/ranking'/name):
                forbidden.extend(case.get('context','')+text for text in case['references'])
        write_json(staged/'replay-exclusions.json',sorted(set(forbidden)))
        shutil.copyfile(coverage/'independent-validation.jsonl',staged/'independent-source.jsonl')
        shutil.copyfile(repo/'config/si.conf',staged/'si.conf')
        shutil.copyfile(source/'si-cli',staged/'si-cli');(staged/'si-cli').chmod(0o700)
        runtime=staged/'runtime'
        for path in code_files()+[REPO/'llm/__init__.py',REPO/'corpus/__init__.py',Path(__file__),Path(__file__).with_name('replay_support.py')]:
            target=runtime/path.relative_to(REPO);target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
        write_json(staged/'config.json',config);write_json(staged/'policy.json',policy);write_json(staged/'paths.json',paths)
        finish_manifest(staged,dict(schema_version=1,kind='si-replay-experiment',code_identity=code_identity(),
            source_pool_dataset_id=pm['dataset_id'],independent_source_dataset_id=cm['dataset_id'],
            independent_validation_seal=cm['validation_seal'],independent_cases=len(rows),initial_sha256=INITIAL_SHA,
            trainer_sha256=file_hash(Path(__file__)),support_sha256=file_hash(Path(__file__).with_name('replay_support.py')),
            note='Identical training data/LR/budget for both arms; only LM replay fraction differs. Old regression is not used for selection.'))
    log('prepared',experiment=str(experiment),independent_cases=len(rows),training_started=False)


@torch.inference_mode()
def selection_metrics(model,tokenizer,rows,lm_validation,config,device):
    was=model.training;model.eval();counts=dict(native_top1=0,queries=len(rows),recalled=0)
    try:
        for row in rows:
            if not row['candidates']:continue
            scores,_=forward_app_pool(model,tokenizer,row,device,config['scoring'])
            values=scores.cpu().tolist()
            order=sorted(range(len(values)),key=lambda i:(-values[i],LANG[row['candidates'][i]['language']],row['candidates'][i]['text']))
            counts['native_top1']+=row['candidates'][order[0]]['text']==row['intended_text']
            counts['recalled']+=any(c['text']==row['intended_text'] for c in row['candidates'])
        lm=validation_loss(model,lm_validation,32,device,max_tokens=65536)
        counts.update(lm_loss=lm['loss'],lm_validation_tokens=lm['tokens'])
        return counts
    finally:model.train(was)


def exposure_count(row,tokenizer,config):
    texts={c['text'] for c,f in zip(row['candidates'],row['model_mask']) if f}
    return sum(len(tokenizer.encode(t))-2 for t in texts)+(len(tokenizer.encode(row['observed_text']))-2 if config['distillation']['lm_weight'] else 0)


def train(experiment,arm,device_name='mps',resume=False):
    identity=manifest_at(experiment,'si-replay-experiment')
    for name in identity['files']:checked_file(experiment,identity,name)
    if code_identity()!=identity['code_identity'] or file_hash(Path(__file__))!=identity['trainer_sha256']:
        raise ValueError('Use this experiment frozen runtime')
    paths=read_json(experiment/'paths.json');config=load_config(experiment/'config.json');policy=read_json(experiment/'policy.json')
    if file_hash(paths['init_checkpoint'])!=INITIAL_SHA:raise ValueError('Initialization archive changed')
    if file_hash(Path(paths['repo'])/'config/si.conf')!=file_hash(experiment/'si.conf'):raise ValueError('App config changed')
    default_name='distill-replay25-v1' if arm=='replay' else 'distill-replay-control-v1'
    run=Path(paths['repo'])/'llm/reranker_large/runs/student-15m-extra-v1'/policy.get('run_names',{}).get(arm,default_name)
    if run.exists() and not resume:raise FileExistsError('Choose resume for an existing run')
    torch.set_num_threads(4);device=select_device(device_name);seed_everything(config['seed'])
    lm,tokenizer,lm_data=load_bundle(paths['lm_data'],config,('train','validation'))
    pm,pools=load_pools(paths['pools'],config,lm,tokenizer,('train','validation'),scored=True)
    rows=list(read_jsonl(experiment/'independent-native.jsonl'))
    parent,initial=load_initialization(paths['init_checkpoint'],config,tokenizer,lm,paths['init_data'])
    model=CharacterLM(config['model'],tokenizer.active_ids).to(device);model.load_state_dict(parent['model']);del parent
    optimizer=torch.optim.AdamW(model.parameters(),lr=config['training']['learning_rate'],betas=(.9,.95),weight_decay=.1)
    forbidden=read_json(experiment/'replay-exclusions.json')
    stream=ReplayStream(lm_data['train'],tokenizer,config['seed']+9001,forbidden)
    fraction=policy['replay_fraction'] if arm=='replay' else 0.
    step=epoch=cursor=kd_targets=replay_targets=stale=0;baseline=best=None;best_step=0
    expected=dict(schema_version=1,kind='si-character-lm',stage='distill',dataset_id=lm['dataset_id'],training_data_id=pm['dataset_id'],
        tokenizer_digest=tokenizer.digest,code_identity=code_identity(),experiment_id=identity['dataset_id'],arm=arm,
        device_type=device.type,torch_version=str(torch.__version__))
    if resume:
        ck=torch.load(run/'last.pt',map_location='cpu',weights_only=True)
        if any(ck.get(k)!=v for k,v in expected.items()):raise ValueError('Replay resume identity differs')
        model.load_state_dict(ck['model']);optimizer.load_state_dict(ck['optimizer'])
        step,epoch,cursor,kd_targets,replay_targets,stale,best_step=(ck[k] for k in ('step','epoch','cursor','kd_targets','replay_targets','stale','best_step'))
        baseline,best=ck['baseline_selection'],ck['best_selection'];stream.restore(ck['replay_state'])
        torch.set_rng_state(ck['torch_rng'])
        if device.type=='mps':torch.mps.set_rng_state(ck['accelerator_rng'])
        if device.type=='cuda':torch.cuda.set_rng_state_all(ck['accelerator_rng'])
        if ck.get('finished'):raise ValueError('This matched experiment already finished')
        del ck
    else:
        run.mkdir(parents=True)
        write_json(run/'run.json',dict(**expected,config=config,teacher=pm['teacher'],initial_checkpoint=initial,policy=policy,
            replay_fraction=fraction,selection_label_status=policy['label_status']))
        baseline=selection_metrics(model,tokenizer,rows,lm_data['validation'],config,device);best=baseline.copy()
        write_json(run/'baseline.json',baseline);log('baseline',arm=arm,**baseline)
    def save(name,finished=False):
        rng=torch.mps.get_rng_state() if device.type=='mps' else torch.cuda.get_rng_state_all() if device.type=='cuda' else None
        atomic_checkpoint(run/name,dict(**expected,config=config,tokenizer=tokenizer.to_dict(),teacher=pm['teacher'],initial_checkpoint=initial,
            model=model.state_dict(),optimizer=optimizer.state_dict(),step=step,epoch=epoch,cursor=cursor,kd_targets=kd_targets,
            replay_targets=replay_targets,tokens_seen=kd_targets+replay_targets,replay_state=stream.state(),
            torch_rng=torch.get_rng_state(),accelerator_rng=rng,stale=stale,best_step=best_step,
            baseline_selection=baseline,best_selection=best,finished=finished))
    if not resume:save('best.pt');save('last.pt')
    model.train();order=None
    while step<config['training']['max_steps']:
        batches=[]
        for _ in range(config['training']['gradient_accumulation']):
            if cursor>=len(pools['train']):epoch+=1;cursor=0;order=None
            if order is None:order=torch.randperm(len(pools['train']),generator=torch.Generator().manual_seed(config['seed']+epoch))
            end=min(len(pools['train']),cursor+config['training']['batch_size']);batches.append(order[cursor:end].tolist());cursor=end
        count=sum(map(len,batches));optimizer.zero_grad(set_to_none=True)
        rate=learning_rate(step+1,config['training'])
        for group in optimizer.param_groups:group['lr']=rate
        total=0.;targets=0
        for batch in batches:
            for index in batch:
                row=pools['train'][index];loss,_=pool_loss(model,tokenizer,row,config,device)
                ((1-fraction)*loss/count).backward();total+=float(loss.detach());targets+=exposure_count(row,tokenizer,config)
        replay_count=replay_budget(targets,fraction);replay_loss=None
        if replay_count:
            inputs,labels=stream.batch(replay_count,device)
            value=F.cross_entropy(model(inputs).float().flatten(0,1),labels.reshape(-1),ignore_index=PAD,reduction='sum')/replay_count
            if not torch.isfinite(value):raise RuntimeError('Nonfinite replay loss')
            (fraction*value).backward();replay_loss=float(value.detach())
        norm=torch.nn.utils.clip_grad_norm_(model.parameters(),1.,error_if_nonfinite=True);optimizer.step()
        step+=1;kd_targets+=targets;replay_targets+=replay_count
        record=dict(step=step,epoch=epoch,cursor=cursor,kd_loss=total/count,replay_lm_loss=replay_loss,
            combined_loss=(1-fraction)*total/count+(fraction*replay_loss if replay_loss is not None else 0),
            kd_targets=kd_targets,replay_targets=replay_targets,learning_rate=rate,gradient_norm=float(norm))
        stop=False
        if step%config['training']['validate_every']==0 or step==config['training']['max_steps']:
            metrics=selection_metrics(model,tokenizer,rows,lm_data['validation'],config,device)
            metrics['lm_increase']=metrics['lm_loss']-baseline['lm_loss']
            metrics['eligible']=eligible_selection(metrics,baseline['lm_loss'],policy['max_lm_increase'])
            if improves_selection(metrics,best,baseline['lm_loss'],policy['max_lm_increase']):
                best=metrics.copy();best_step=step;stale=0;save('best.pt')
            else:stale+=1
            metrics['best_step']=best_step;metrics['stale_checks']=stale;record['selection']=metrics
            record['kd_validation']=validate_distillation(model,tokenizer,pools['validation'],config,device)
            stop=stale>=policy['patience_checks']
            # Check frozen provenance at every acceptance boundary.
            if file_hash(paths['init_checkpoint'])!=INITIAL_SHA:raise ValueError('Initialization changed')
        with (run/'metrics.jsonl').open('a') as output:output.write(json.dumps(record,allow_nan=False)+'\n')
        log('train',arm=arm,**record)
        finished=stop or step>=config['training']['max_steps']
        if step%config['training']['save_every']==0 or finished:save('last.pt',finished)
        if stop:break
    result=dict(arm=arm,steps=step,best_step=best_step,baseline=baseline,best=best,
        replay_fraction=fraction,actual_replay_target_fraction=replay_targets/(kd_targets+replay_targets),
        stopped_for_patience=stale>=policy['patience_checks'],selected_is_pretraining=best_step==0,
        note='Selection labels are score-blind synthetic intentions, not human-reviewed gold. Old regression not consulted.')
    write_json(run/'result.json',result);log('complete',**result)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=('prepare','train'));parser.add_argument('--repo',type=Path,default=REPO)
    parser.add_argument('--experiment',type=Path,required=True);parser.add_argument('--arm',choices=('control','replay'),default='replay')
    parser.add_argument('--device',choices=('mps','cpu','cuda'),default='mps');parser.add_argument('--resume',action='store_true')
    parser.add_argument('--learning-rate',type=float,help='Preparation only: freeze a separate learning-rate experiment')
    parser.add_argument('--run-tag',help='Preparation only: suffix for distinct versioned run directories')
    args=parser.parse_args()
    if args.stage=='prepare':prepare(args.repo.resolve(),args.experiment.resolve(),args.learning_rate,args.run_tag)
    else:
        if args.learning_rate is not None or args.run_tag is not None:parser.error('Training uses the frozen experiment settings')
        train(args.experiment.resolve(),args.arm,args.device,args.resume)


if __name__=='__main__':main()
