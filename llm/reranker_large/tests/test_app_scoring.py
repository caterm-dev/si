"""App score equivalence and tiny synthetic distillation; no real Qwen/corpus."""
import contextlib
import copy
import io
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import torch

from llm.export_rust import export as export_rust
from llm.reranker_large.app_scoring import bonus_tensor, bonus_values, pool_bonus_values
from llm.reranker_large.data import PoolWriter, load_pools
from llm.reranker_large.evaluate import predict
from llm.reranker_large.fixtures import SyntheticTeacher, fixture
from llm.reranker_large.prepare import finish_manifest, prepare_documents, prepare_pools
from llm.reranker_large.scoring import forward_pool, validate_pool
from llm.reranker_large.settings import APP_PROTOCOL, REPO, ROOT, read_json, score_mapping, write_json
from llm.reranker_large.teacher import cache_teacher
from llm.reranker_large.train import train
from llm.reranker_small.data import load_bundle
from llm.reranker_small.model import CharacterLM
from llm.reranker_small.runtime import atomic_checkpoint, load_checkpoint
from llm.reranker_small.tokenizer import Tokenizer

PARAMS=dict(model_score_weight=0.8,model_score_gap_limit_bits=8.0,model_sentence_reward_cap_bits=8.0)


class AppScoringTests(unittest.TestCase):
    def test_old_per_scalar_and_lift_app_protocols_are_rejected(self):
        config=read_json(ROOT/'configs/distill-app-v4.json')
        self.assertEqual(score_mapping(config),dict(protocol=APP_PROTOCOL,app=PARAMS))
        for protocol in ('si-app-model-adjustment-v1','si-app-model-adjustment-v2','si-app-model-adjustment-v3'):
            config['scoring']['protocol']=protocol
            with self.assertRaisesRegex(ValueError,'protocol'):
                score_mapping(config)

    def test_exact_adjustments_and_probability_gradient_paths(self):
        log=math.log(2)
        baseline=torch.tensor([-4*log,-8*log,-100*log],requires_grad=True)
        conditional=torch.tensor([-3*log,-4*log,-102*log],requires_grad=True)
        texts=['好','你好','🙂']
        bos=bonus_tensor(conditional,baseline,texts,False,PARAMS)
        self.assertTrue(torch.allclose(bos,torch.tensor([0.,-3.2,-6.4]),atol=1e-5))
        self.assertTrue(torch.allclose(bos,bonus_tensor(conditional,baseline,['你好','好','🙂'],False,PARAMS)))
        for value,expected in zip(bonus_values([],baseline.detach().tolist(),texts,False,PARAMS),[0.,-3.2,-6.4]):
            self.assertAlmostEqual(value,expected,places=5)
        bos[1].backward(retain_graph=True)
        self.assertNotEqual(float(baseline.grad[0]),0)
        self.assertNotEqual(float(baseline.grad[1]),0)
        baseline.grad.zero_()
        contextual=bonus_tensor(conditional,baseline,texts,True,PARAMS)
        self.assertTrue(torch.allclose(contextual,torch.tensor([0.,-0.8,-6.4]),atol=1e-5))
        for value,expected in zip(bonus_values([-3*log,-4*log,-102*log],[-4*log,-8*log,-100*log],texts,True,PARAMS),[0.,-0.8,-6.4]):
            self.assertAlmostEqual(value,expected)
        contextual[1].backward()
        self.assertNotEqual(float(conditional.grad[0]),0)
        self.assertNotEqual(float(conditional.grad[1]),0)
        self.assertTrue(torch.equal(baseline.grad,torch.zeros_like(baseline)))
        capped=bonus_tensor(torch.tensor([-100.,0.]),torch.tensor([0.,0.]),['甲','乙'],True,PARAMS)
        self.assertTrue(torch.equal(capped,torch.tensor([-6.4,0.])))

    def test_conditional_probability_ignores_rare_candidate_baseline_lift(self):
        log=math.log(2)
        conditional=torch.tensor([-11.32*log,-20.31*log])
        baseline=torch.tensor([-13.44*log,-24.84*log])
        texts=['好吗','号吗']
        self.assertGreater(float((conditional-baseline)[1]),float((conditional-baseline)[0]))
        expected=torch.tensor([0.,-6.4])
        self.assertTrue(torch.equal(bonus_tensor(conditional,baseline,texts,True,PARAMS),expected))
        self.assertTrue(torch.equal(bonus_tensor(conditional,baseline*100,texts,True,PARAMS),expected))
        for value,target in zip(bonus_values(conditional.tolist(),baseline.tolist(),texts,True,PARAMS),[0.,-6.4]):
            self.assertAlmostEqual(value,target)

    def test_forward_matches_native_app_adjustments_with_statistical_fusion(self):
        binary=REPO/'target/release/si-cli'
        if not binary.exists():self.skipTest('Build Release si-cli')
        config=read_json(ROOT/'configs/smoke.json')
        config['scoring'].update(protocol=APP_PROTOCOL,app=PARAMS,context_tokens=16,candidate_tokens=16)
        tokenizer=Tokenizer(512,list(dict.fromkeys('今天下午我们一起开会慧你好您好')))
        torch.manual_seed(7)
        model=CharacterLM(config['model'],tokenizer.active_ids).eval()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            checkpoint=root/'model.pt'
            atomic_checkpoint(checkpoint,dict(schema_version=1,kind='si-character-lm',config=config,
                model=model.state_dict(),tokenizer=tokenizer.to_dict(),tokenizer_digest=tokenizer.digest,
                dataset_id='authored-fixture',step=0))
            export_rust('reranker',checkpoint,root/'rust')
            legacy_cli=binary.with_name('si-neural')
            if legacy_cli.exists():
                legacy=subprocess.run([str(legacy_cli),'rank',str(root/'rust')],
                                      input='',text=True,capture_output=True)
                self.assertNotEqual(legacy.returncode,0)
                self.assertIn('App-aligned bundles require si-cli',legacy.stderr)
            for context in ('','今天下午我们一起'):
                texts=['开会','开慧','你好']
                candidates=[dict(text=t,language='zh-Hans') for t in texts]
                candidates += [dict(text='好麻',language='zh-Hans'),dict(text='开会',language='en'),
                               dict(text='开会',language='mixed')]
                row=dict(context=context,observed_text='开会',candidates=candidates,
                         base_scores_bits=[-10.,-11.,-12.,-13.,-14.,-15.],model_mask=[True]*3+[False]*3,
                         model_adjustment_mask=[True]*5+[False])
                self.assertTrue(validate_pool(row,tokenizer,config))
                stale=copy.deepcopy(config)
                stale['scoring']['protocol']='si-app-model-adjustment-v3'
                stale_row={**row,**{key:row[key][:3] for key in
                    ('candidates','base_scores_bits','model_mask','model_adjustment_mask')}}
                with self.assertRaisesRegex(ValueError,'Unsupported scoring protocol'):
                    predict(model,tokenizer,stale_row,stale,torch.device('cpu'))
                with self.assertRaisesRegex(ValueError,'Unsupported scoring protocol'):
                    forward_pool(model,tokenizer,stale_row,torch.device('cpu'),stale['scoring'])
                with torch.inference_mode():scores,_=forward_pool(model,tokenizer,row,torch.device('cpu'),config['scoring'])
                result=subprocess.run([str(binary),'model-adjustments',str(root/'rust')],
                    input=context+'\t'+'\t'.join(texts)+'\n',text=True,capture_output=True,check=True)
                values=[float(s) for s in result.stdout.strip().split('\t')]
                for value,base,actual in zip(values,row['base_scores_bits'][:3],scores.tolist()[:3],strict=True):
                    self.assertAlmostEqual(value+base,actual,delta=.005)
                self.assertLess(min(values),0)
                self.assertAlmostEqual(float(scores[3]),-13.+min(values),delta=.005)
                self.assertAlmostEqual(float(scores[4]),-14.+values[0],delta=.005)
                self.assertEqual(float(scores[5]),-15.)
                self.assertEqual(pool_bonus_values(candidates,row['model_adjustment_mask'],texts,values),
                                 values+[min(values),values[0],0.])
                row['model_mask']=[False]*6
                with torch.inference_mode():scores,_=forward_pool(model,tokenizer,row,torch.device('cpu'),config['scoring'])
                self.assertEqual(scores.tolist(),row['base_scores_bits'])
            # The limit counts tokenizer targets, including byte fallback.
            for texts,eligible in [(['好'*16,'𠀀'*4],True),(['好'*16,'𠀀'*4+'好'],False)]:
                context='好'*16
                row=dict(context=context,observed_text='开会',
                         candidates=[dict(text=t,language='zh-Hans') for t in texts],
                         base_scores_bits=[-10.,-11.],model_mask=[True,True],model_adjustment_mask=[True,True])
                self.assertEqual(validate_pool(row,tokenizer,config),eligible)
                result=subprocess.run([str(binary),'model-adjustments',str(root/'rust')],
                    input=context+'\t'+'\t'.join(texts)+'\n',text=True,capture_output=True,check=True)
                if eligible:
                    with torch.inference_mode():scores,_=forward_pool(model,tokenizer,row,torch.device('cpu'),config['scoring'])
                    for bonus,base,actual in zip(map(float,result.stdout.strip().split('\t')),row['base_scores_bits'],scores.tolist(),strict=True):
                        self.assertAlmostEqual(bonus+base,actual,delta=.005)
                else:
                    self.assertEqual(result.stdout.strip(),'abstained')

    def test_native_pool_export_uses_live_selection_and_fragment_boundaries(self):
        from llm.reranker_large.scripts.prepare_app_teacher import NativePools
        binary=REPO/'target/release/si-cli'
        if not binary.exists():self.skipTest('Build Release si-cli')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            shutil.copyfile(binary,root/'si-cli');(root/'si-cli').chmod(0o700)
            shutil.copyfile(REPO/'config/si.conf',root/'si.conf')
            (root/'words.csv').write_text("text,reading,weight\n你好,ni'hao,100\n拟好,ni'hao,90\n你好吗,ni'hao'ma,50\n你,ni,200\n")
            def run(*args):subprocess.run([str(binary),*map(str,args)],capture_output=True,check=True)
            run('lexicon','build',root/'main.silex','0',root/'words.csv')
            (root/'text.txt').write_text('你 你好\n')
            run('corpus','build',root/'main.silex',root/'words.sigram',root/'text.txt')
            native=NativePools(root)
            try:
                context,candidates,scores,mask,adjustment_mask=native.query('nihao','之前的内容。今天')
                self.assertEqual(context,'今天')
                self.assertEqual({c['text'] for c,f in zip(candidates,mask) if f},{'你好','拟好'})
                self.assertTrue(all(math.isfinite(s) for s in scores))
                if any(c['text']=='你好吗' for c in candidates):
                    index=next(i for i,c in enumerate(candidates) if c['text']=='你好吗')
                    self.assertFalse(mask[index])
                    self.assertTrue(adjustment_mask[index])
            finally:native.close()

    def test_app_cache_protocol_fresh_training_and_exact_resume(self):
        torch.set_num_threads(1)
        with tempfile.TemporaryDirectory() as directory,contextlib.redirect_stdout(io.StringIO()):
            root=Path(directory)
            pre,kd,provenance,documents,records=fixture(root/'inputs')
            lm,pools,teacher=(root/n for n in ('lm','pools','teacher'))
            prepare_documents(pre,documents,provenance,lm)
            prepare_pools(pre,lm,records,provenance,pools)
            cache_teacher(pre,lm,pools,teacher,SyntheticTeacher())
            train(pre,lm,root/'pre','cpu',max_steps=1,threads=1)
            config=read_json(kd)
            config['scoring'].update(protocol=APP_PROTOCOL,app=PARAMS)
            write_json(root/'app.json',config)
            manifest,tokenizer,_=load_bundle(lm,config,('train',))
            with self.assertRaisesRegex(ValueError,'protocol'):
                load_pools(teacher,config,manifest,tokenizer,('train',),scored=True)
            old=read_json(teacher/'manifest.json')
            for protocol in ('si-app-model-adjustment-v1','si-app-model-adjustment-v2','si-app-model-adjustment-v3'):
                obsolete={k:v for k,v in old.items() if k!='dataset_id'}
                obsolete['score_mapping']=dict(protocol=protocol,app=PARAMS)
                finish_manifest(teacher,obsolete)
                with self.assertRaisesRegex(ValueError,'protocol'):
                    load_pools(teacher,config,manifest,tokenizer,('train',),scored=True)
            write_json(teacher/'manifest.json',old)
            destination=root/'app-teacher';destination.mkdir()
            shutil.copyfile(teacher/'NOTICE.md',destination/'NOTICE.md')
            for split in ('train','validation','test'):
                writer=PoolWriter(destination,split)
                try:
                    for row in [json.loads(line) for line in (teacher/(split+'.jsonl')).read_text().splitlines()]:
                        legacy_scores=row.pop('teacher_scores',None)
                        n=len(row['candidates'])
                        row['candidates'].append(dict(text='这是不接受模型评分的较长候选',language='zh-Hans'))
                        row.update(base_scores_bits=[-10.-i for i in range(n)]+[-100.],model_mask=[True]*n+[False],model_adjustment_mask=[True]*(n+1))
                        if split!='test':
                            baseline=[-6. if c['text']=='登录' else -4. for c in row['candidates'][:n]]
                            bonuses=bonus_values(legacy_scores,baseline,[c['text'] for c in row['candidates'][:n]],bool(row['context']),PARAMS)
                            row.update(teacher_conditional_logp=legacy_scores+[None],teacher_baseline_logp=baseline+[None],
                                       teacher_scores=[b+v for b,v in zip(row['base_scores_bits'][:n],bonuses)]+[-100.+min(bonuses)])
                        self.assertTrue(validate_pool(row,tokenizer,config))
                        writer.append(row)
                finally:writer.close()
            finish_manifest(destination,dict(schema_version=1,kind='si-student-pools',lm_dataset_id=manifest['dataset_id'],
                tokenizer_digest=tokenizer.digest,limits=old['limits'],score_mapping=score_mapping(config),
                splits=old['splits'],teacher=dict(protocol=APP_PROTOCOL)))
            common=dict(pools_path=destination,threads=1)
            train(root/'app.json',lm,root/'whole','cpu',init_checkpoint=root/'pre/best.pt',max_steps=2,**common)
            train(root/'app.json',lm,root/'resumed','cpu',init_checkpoint=root/'pre/best.pt',max_steps=1,**common)
            train(root/'app.json',lm,root/'resumed','cpu',resume=True,max_steps=2,**common)
            full=torch.load(root/'whole/last.pt',weights_only=True)
            resumed=torch.load(root/'resumed/last.pt',weights_only=True)
            for key in full['model']:self.assertTrue(torch.equal(full['model'][key],resumed['model'][key]),key)
            checkpoint,model,tok=load_checkpoint(root/'whole/best.pt',torch.device('cpu'))
            _,data=load_pools(destination,config,manifest,tok,('validation',),scored=True)
            prediction=predict(model,tok,data['validation'][0],config,torch.device('cpu'))
            self.assertEqual(prediction['protocol'],APP_PROTOCOL)
            self.assertTrue(all(math.isfinite(s) for s in prediction['scores']))

    def test_teacher_upgrade_resumes_and_never_scores_test(self):
        from llm.reranker_large.scripts import prepare_app_teacher as producer
        from llm.reranker_large.teacher import PROTOCOL
        from llm.pinyin_to_text.common import file_hash,read_jsonl,write_jsonl
        binary=REPO/'target/release/si-cli'
        if not binary.exists():self.skipTest('Build Release si-cli')
        with tempfile.TemporaryDirectory() as directory,contextlib.redirect_stdout(io.StringIO()):
            root=Path(directory)
            pre,kd,provenance,documents,records=fixture(root/'inputs')
            legacy=read_json(pre);legacy['scoring'].update(context_tokens=16,candidate_tokens=16)
            write_json(pre,legacy)
            rows=list(read_jsonl(records))
            for row in rows:row['case']=dict(context='short',target='word',input='complete',mixed_target=False)
            write_jsonl(records,rows)
            lm,pools,old=(root/n for n in ('lm','pools','old'))
            prepare_documents(pre,documents,provenance,lm)
            prepare_pools(pre,lm,records,provenance,pools)
            model=root/'qwen-fixture';model.mkdir();(model/'fixture.bin').write_bytes(b'authored synthetic model fixture')
            teacher=SyntheticTeacher()
            teacher.identity=dict(model_id='synthetic-only-qwen-test',protocol=PROTOCOL,
                                  files={'fixture.bin':file_hash(model/'fixture.bin')})
            cache_teacher(pre,lm,pools,old,teacher)
            old_pin=file_hash(old/'manifest.json')
            app=copy.deepcopy(legacy);app['stage']='distill';app['scoring'].update(protocol=APP_PROTOCOL,app=PARAMS)
            write_json(root/'app.json',app)
            engine=(REPO/'config/si.conf').read_text().replace('model_candidate_limit = 12','model_candidate_limit = 4')
            (root/'si.conf').write_text(engine)
            (root/'words.csv').write_text("text,reading,weight\n登录,deng'lu,100\n登陆,deng'lu,90\n开会,kai'hui,100\n开慧,kai'hui,90\n")
            def cli(*args):subprocess.run([str(binary),*map(str,args)],check=True,capture_output=True)
            cli('lexicon','build',root/'main.silex','0',root/'words.csv')
            (root/'text.txt').write_text('登录 开会\n')
            cli('corpus','build',root/'main.silex',root/'words.sigram',root/'text.txt')
            args=['producer','--config',str(root/'app.json'),'--data',str(lm),'--source',str(old),
                  '--output',str(root/'new'),'--model',str(model),'--binary',str(binary),
                  '--lexicon',str(root/'main.silex'),'--grams',str(root/'words.sigram'),
                  '--engine-config',str(root/'si.conf'),'--device','cpu']
            class FakeQwen:
                fail=True
                def __init__(self,*args):self.identity=teacher.identity
                def sequence_scores(self,context,texts):
                    if FakeQwen.fail:raise RuntimeError('synthetic interruption')
                    return [-2.*len(t) for t in texts]
                def verify(self):pass
            with patch.object(producer,'QwenTeacher',FakeQwen),patch('sys.argv',args):
                with self.assertRaisesRegex(RuntimeError,'synthetic interruption'):producer.main()
            self.assertFalse((root/'new').exists())
            FakeQwen.fail=False
            with patch.object(producer,'QwenTeacher',FakeQwen),patch('sys.argv',args+['--resume']):producer.main()
            manifest=read_json(root/'new/manifest.json')
            self.assertEqual(manifest['score_mapping'],score_mapping(app))
            self.assertEqual(manifest['scored_splits'],['train','validation'])
            for split in ('train','validation','test'):
                for row in read_jsonl(root/f'new/{split}.jsonl'):
                    self.assertTrue(validate_pool(row,Tokenizer.load(lm/'tokenizer.json'),app))
                    self.assertEqual('teacher_scores' in row,split!='test')
            self.assertEqual(file_hash(old/'manifest.json'),old_pin)
            # A scoring-rule revision reuses raw likelihoods, never fused logits.
            remap_args=list(args)
            remap_args[remap_args.index('--output')+1]=str(root/'remapped')
            remap_args+=['--likelihood-cache',str(root/'new')]
            with patch.object(producer,'QwenTeacher',side_effect=AssertionError('Qwen must not load')),patch('sys.argv',remap_args):
                producer.main()
            remapped=read_json(root/'remapped/manifest.json')
            self.assertEqual(remapped['generation']['likelihood_cache_dataset_id'],manifest['dataset_id'])
            for split in ('train','validation','test'):
                self.assertEqual(list(read_jsonl(root/f'new/{split}.jsonl')),
                                 list(read_jsonl(root/f'remapped/{split}.jsonl')))
            # v3 likelihoods remain reusable without importing its old zero-adjustment policy.
            old_cache=root/'v3-cache'
            shutil.copytree(root/'new',old_cache)
            for split in ('train','validation','test'):
                rows=list(read_jsonl(old_cache/f'{split}.jsonl'))
                writer=PoolWriter(old_cache,split)
                try:
                    for row in rows:
                        row.pop('model_adjustment_mask')
                        if 'teacher_scores' in row:
                            row['teacher_scores']=[999.]*len(row['candidates'])
                        writer.append(row)
                finally:writer.close()
            old_manifest={k:v for k,v in manifest.items() if k!='dataset_id'}
            old_manifest['score_mapping']=dict(protocol='si-app-model-adjustment-v3',app=PARAMS)
            finish_manifest(old_cache,old_manifest)
            old_args=list(remap_args)
            old_args[old_args.index('--output')+1]=str(root/'v3-remapped')
            old_args[old_args.index('--likelihood-cache')+1]=str(old_cache)
            with patch.object(producer,'QwenTeacher',side_effect=AssertionError('Qwen must not load')),patch('sys.argv',old_args):
                producer.main()
            for split in ('train','validation','test'):
                self.assertEqual(list(read_jsonl(root/f'new/{split}.jsonl')),
                                 list(read_jsonl(root/f'v3-remapped/{split}.jsonl')))


if __name__=='__main__':unittest.main()
