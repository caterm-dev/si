"""Synthetic sequence-KL gradient, cache preparation and resume regressions."""

import contextlib
import copy
import io
import math
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import torch

from llm.pinyin_to_text.common import file_hash, read_json, read_jsonl, write_json
from llm.reranker_large.app_scoring import bonus_tensor, bonus_values, pool_bonus_values
from llm.reranker_large.data import PoolWriter, load_pools
from llm.reranker_large.export import export
from llm.reranker_large.fixtures import fixture, SyntheticTeacher
from llm.reranker_large.prepare import finish_manifest, prepare_documents, prepare_pools
from llm.reranker_large.scoring import distillation_loss
from llm.reranker_large.sequence_distillation import pool_loss, sequence_logits
from llm.reranker_large.settings import APP_PROTOCOL, REPO, ROOT, SEQUENCE_KD, load_config, score_mapping, training_objective
from llm.reranker_large.teacher import cache_teacher
from llm.reranker_large.train import train
from llm.reranker_small.data import load_bundle
from llm.reranker_small.model import CharacterLM
from llm.reranker_small.runtime import load_checkpoint

PARAMS = dict(model_score_weight=0.8, model_score_gap_limit_bits=8.0, model_sentence_reward_cap_bits=8.0)


class SequenceDistillationTests(unittest.TestCase):
    def test_uncapped_sequence_loss_recovers_gradient_for_wrong_capped_candidate(self):
        log = math.log(2)
        student = torch.tensor([-1.*log, -30.*log], requires_grad=True)
        teacher = torch.tensor([-30.*log, -1.*log])
        settings = dict(temperature=2.,kd_weight=1.,lm_weight=0.,label_weight=0.)
        capped = bonus_tensor(student,student,['甲','乙'],True,PARAMS)
        wanted = bonus_tensor(teacher,teacher,['甲','乙'],True,PARAMS)
        loss,_ = distillation_loss(capped,wanted,student.new_zeros(()),settings)
        gradient, = torch.autograd.grad(loss,student)
        self.assertGreater(float(loss.detach()),0)
        self.assertEqual(gradient.abs().sum().item(),0)
        loss,_ = distillation_loss(sequence_logits(student,.8),sequence_logits(teacher,.8),
                                   student.new_zeros(()),settings)
        gradient, = torch.autograd.grad(loss,student)
        self.assertTrue(torch.isfinite(gradient).all())
        self.assertGreater(float(gradient[0]),0)
        self.assertLess(float(gradient[1]),0)
        shifted = sequence_logits(student.detach()-100,.8)
        self.assertTrue(torch.allclose(shifted,sequence_logits(student.detach(),.8),atol=1e-5))

    def test_sequence_objective_uses_unique_model_texts_not_statistical_competitors(self):
        config=read_json(ROOT/'configs/smoke.json')
        config['stage']='distill'
        config['scoring'].update(protocol=APP_PROTOCOL,app=PARAMS)
        config['distillation'].update(objective=SEQUENCE_KD,label_weight=0.)
        from llm.reranker_small.tokenizer import Tokenizer
        tokenizer=Tokenizer(512,list('今天开会慧'))
        torch.manual_seed(7)
        model=CharacterLM(config['model'],tokenizer.active_ids).eval()
        row=dict(context='今天',observed_text='开会',candidates=[dict(text=t,language='zh-Hans') for t in ('开会','开慧')],
                 model_mask=[True,True],teacher_conditional_logp=[-2.,-5.],base_scores_bits=[-10.,-20.])
        first=pool_loss(model,tokenizer,row,config,torch.device('cpu'))
        other=copy.deepcopy(row)
        other['candidates'] += [dict(text='开会',language='en'),dict(text='unscored competitor',language='en')]
        other['model_mask'] += [True,False]
        other['teacher_conditional_logp'] += [-2.,None]
        other['base_scores_bits'] = [900.,-2000.,12.,1000.]
        second=pool_loss(model,tokenizer,other,config,torch.device('cpu'))
        for a,b in zip(first,second):self.assertTrue(torch.allclose(a,b,atol=1e-6))
        other['teacher_conditional_logp'][2]=-3.
        with self.assertRaisesRegex(ValueError,'inconsistent likelihoods'):
            pool_loss(model,tokenizer,other,config,torch.device('cpu'))

    def test_prepared_cache_exact_resume_and_inference_provenance(self):
        from llm.reranker_large.scripts import prepare_sequence_kd as producer
        torch.set_num_threads(1)
        with tempfile.TemporaryDirectory() as directory,contextlib.redirect_stdout(io.StringIO()):
            root=Path(directory)
            pre,kd,provenance,documents,records=fixture(root/'inputs')
            lm,pools,teacher=(root/name for name in ('lm','pools','teacher'))
            prepare_documents(pre,documents,provenance,lm)
            prepare_pools(pre,lm,records,provenance,pools)
            cache_teacher(pre,lm,pools,teacher,SyntheticTeacher())
            train(pre,lm,root/'pre','cpu',max_steps=1,threads=1)
            config=read_json(kd)
            config['scoring'].update(protocol=APP_PROTOCOL,app=PARAMS)
            config['distillation'].update(objective=SEQUENCE_KD,label_weight=0.)
            write_json(root/'sequence.json',config)
            native=(REPO/'config/si.conf').read_text().replace('model_candidate_limit = 12','model_candidate_limit = 4')
            native=native.replace('model_context_token_limit = 16','model_context_token_limit = 8')
            native=native.replace('model_candidate_token_limit = 16','model_candidate_token_limit = 8')
            (root/'si.conf').write_text(native)
            (root/'Data/Engine').mkdir(parents=True)
            (root/'Data/Engine/main.silex').write_bytes(b'synthetic resource identity only')
            (root/'Data/Engine/words.sigram').write_bytes(b'synthetic gram identity only')
            source=root/'app-source';source.mkdir()
            shutil.copyfile(teacher/'NOTICE.md',source/'NOTICE.md')
            shutil.copyfile(teacher/'source-lock.json',source/'source-lock.json')
            meta=source/'metadata/app-alignment';meta.mkdir(parents=True)
            resources={name:dict(sha256=file_hash(path)) for name,path in (
                ('si.conf',root/'si.conf'),('main.silex',root/'Data/Engine/main.silex'),('words.sigram',root/'Data/Engine/words.sigram'))}
            write_json(meta/'identity.json',dict(resources=resources))
            old=read_json(teacher/'manifest.json')
            for split in ('train','validation','test'):
                writer=PoolWriter(source,split)
                try:
                    for i,row in enumerate(read_jsonl(teacher/(split+'.jsonl'))):
                        raw=row.pop('teacher_scores',None)
                        n=len(row['candidates']);mask=[i==0]*n
                        row.update(base_scores_bits=[-10.-j for j in range(n)],model_mask=mask,
                                   model_adjustment_mask=[True]*n,case=dict(input='complete'))
                        if split!='test':
                            baseline=[-4.]*n
                            texts=list(dict.fromkeys(c['text'] for c in row['candidates']))
                            cond={c['text']:v for c,v in zip(row['candidates'],raw)}
                            bonuses=bonus_values([cond[t] for t in texts],[-4.]*len(texts),texts,True,PARAMS) if i==0 else []
                            adjustments=pool_bonus_values(row['candidates'],[True]*n,texts if i==0 else [],bonuses)
                            row.update(teacher_conditional_logp=raw if i==0 else [None]*n,
                                       teacher_baseline_logp=baseline if i==0 else [None]*n,
                                       teacher_scores=[b+a for b,a in zip(row['base_scores_bits'],adjustments)])
                        writer.append(row)
                finally:writer.close()
            lm_manifest,tok,_=load_bundle(lm,config,('validation',))
            finish_manifest(source,dict(schema_version=1,kind='si-student-pools',lm_dataset_id=lm_manifest['dataset_id'],
                tokenizer_digest=tok.digest,limits=old['limits'],score_mapping=score_mapping(config),
                splits=old['splits'],teacher=dict(protocol=APP_PROTOCOL),scored_splits=['train','validation']))
            pin=file_hash(source/'manifest.json')
            with self.assertRaisesRegex(ValueError,'active-pool derivative'):
                load_pools(source,config,lm_manifest,tok,('train',),scored=True)
            dest=root/'sequence-pools'
            with patch.object(producer,'REPO',root):
                result=producer.prepare(root/'sequence.json',lm,source,dest,root/'si.conf')
            self.assertEqual(result['training_objective'],SEQUENCE_KD)
            self.assertEqual(result['splits'],{s:dict(pools=1) for s in ('train','validation','test')})
            for split in ('train','validation','test'):
                row=next(iter(read_jsonl(dest/(split+'.jsonl'))))
                self.assertNotIn('reference_indices',row)
                self.assertNotIn('labels_reviewed',row)
                self.assertEqual('teacher_scores' in row,split!='test')
            common=dict(pools_path=dest,threads=1)
            check=train(root/'sequence.json',lm,root/'check','cpu',init_checkpoint=root/'pre/best.pt',check_only=True,**common)
            self.assertFalse((root/'check').exists())
            self.assertFalse(check['training_started'])
            train(root/'sequence.json',lm,root/'whole','cpu',init_checkpoint=root/'pre/best.pt',max_steps=2,**common)
            train(root/'sequence.json',lm,root/'resume','cpu',init_checkpoint=root/'pre/best.pt',max_steps=1,**common)
            train(root/'sequence.json',lm,root/'resume','cpu',resume=True,max_steps=2,**common)
            full=torch.load(root/'whole/last.pt',weights_only=True)
            resumed=torch.load(root/'resume/last.pt',weights_only=True)
            for name in full['model']:self.assertTrue(torch.equal(full['model'][name],resumed['model'][name]),name)
            # Inference still uses App v4, while the training objective stays explicit.
            exported=export(root/'whole/best.pt',lm,root/'export',dest)
            manifest=read_json(root/'export/rust/model.json')
            self.assertEqual(manifest['score_protocol'],APP_PROTOCOL)
            self.assertEqual(exported['teacher']['protocol'],APP_PROTOCOL)
            self.assertEqual(file_hash(source/'manifest.json'),pin)
            stale=copy.deepcopy(config);stale['distillation']['label_weight']=1.
            with self.assertRaisesRegex(ValueError,'supervised labels'):training_objective(stale)
            with patch.object(producer,'REPO',root):
                with self.assertRaises(FileExistsError):producer.prepare(root/'sequence.json',lm,source,dest,root/'si.conf')


if __name__=='__main__':
    unittest.main()
