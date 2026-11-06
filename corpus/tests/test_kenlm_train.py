import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from kenlm_train import block_split, prepare, verify_split, parse_query, CONFIGS, compare, write_report, train_one, audit_blocks

class KenLMTrainingTests(unittest.TestCase):
    def test_discount_failure_retries_with_fallback_and_preserves_requested_binary_options(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);data=root/'data';data.mkdir();tools=root/'bin';tools.mkdir()
            for name in ('lmplz','build_binary','query'):(tools/name).write_bytes(name.encode())
            (data/'manifest.json').write_text(json.dumps({'splits':{'train':{'lines':100000}}}))
            (data/'smoke-train.txt').write_text('测试 。\n'*100000)
            (data/'smoke-heldout.txt').write_text('测试 。\n')
            commands=[]
            def execute(command,input_path,output_path,log_path,journal):
                commands.append([str(c) for c in command]);program=Path(command[0]).name
                log_path.write_text('')
                if program=='lmplz' and '--discount_fallback' not in command:
                    output_path.write_bytes(b'partial');log_path.write_text('BadDiscountException: rerun with --discount_fallback')
                    return {'exit_code':1,'seconds':0.1}
                if program=='lmplz':output_path.write_text('\\data\\\nngram 1=3\nngram 2=2\nngram 3=1\n\\1-grams:\n')
                elif program=='build_binary':Path(command[-1]).write_bytes(b'synthetic trie');output_path.write_bytes(b'')
                else:output_path.write_text('Perplexity including OOVs: 10\nPerplexity excluding OOVs: 9\nOOVs: 0\nTokens: 3\n')
                return {'exit_code':0,'seconds':0.1}
            with patch('kenlm_train.run_command',side_effect=execute):
                result=train_one('o3',root,tools,smoke=True)
            self.assertTrue(result['discount_fallback'])
            self.assertEqual(commands[0][1:],['-o','3','-S','40%','-T','/tmp','--prune','0','0','1'])
            self.assertEqual(commands[1][1:],commands[0][1:]+['--discount_fallback'])
            self.assertEqual(commands[2][1:10],['-S','40%','-T','/tmp','-q','8','-b','8','trie'])
            self.assertFalse((root/'smoke/o3/model.arpa').exists())

    def test_all_smokes_precede_full_training_and_failed_smoke_stops_the_run(self):
        with tempfile.TemporaryDirectory() as folder:
            run=Path(folder);calls=[]
            def train(name,run,tools,smoke=False):
                calls.append((name,smoke))
                return {'configuration':name}
            with patch('kenlm_train.train_one',side_effect=train), patch('kenlm_train.write_report'):
                compare(run,run/'tools')
            self.assertEqual(calls,[(n,True) for n in CONFIGS]+[(n,False) for n in CONFIGS])
            calls.clear()
            def fail(name,run,tools,smoke=False):
                calls.append((name,smoke))
                if name=='o4b':raise RuntimeError('Synthetic smoke failure')
            with patch('kenlm_train.train_one',side_effect=fail), self.assertRaises(RuntimeError):
                compare(run,run/'tools')
            self.assertTrue(all(smoke for _,smoke in calls))

    def test_recommendation_requires_complete_comparable_models_and_prefers_size_within_tolerance(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'data').mkdir()
            split={'splits':{'train':{'sha256':'a'},'heldout':{'sha256':'b','lines':2,'tokens':4}}}
            (root/'data/manifest.json').write_text(json.dumps(split))
            results=[]
            for name,ppl,size in [('o3',105,5),('o4a',100.5,10),('o4b',100.3,20),('o5',100,30)]:
                dest=root/'models'/name;dest.mkdir(parents=True)
                (dest/'model.trie').write_bytes(b'x'*size)
                text=f'Perplexity including OOVs: {ppl}\nPerplexity excluding OOVs: {ppl-10}\nOOVs: 1\nTokens: 6\n'
                (dest/'query.stdout').write_text(text);(dest/'query.stderr').write_text('')
                order,prune=CONFIGS[name]
                results.append({'configuration':name,'identity':{'smoke':False,'training_sha256':'a','evaluation_sha256':'b',
                    'order':order,'prune':prune,'memory':'40%','temporary_directory':'/tmp','binary_type':'trie',
                    'probability_bits':8,'backoff_bits':8},'binary_bytes':size,
                    'binary_sha256':hashlib.sha256(b'x'*size).hexdigest(),'training_seconds':1,'binary_build_seconds':1,
                    'total_training_seconds':2,'query_seconds':1,'discount_fallback':False,**parse_query(text)})
            selected=write_report(root,results)
            self.assertEqual(selected['recommended_configuration'],'o4a')
            self.assertFalse(selected['final_combined_data_training_performed'])
            with self.assertRaisesRegex(ValueError,'All four'):write_report(root,results[:3])

    def test_dedup_first_occurrence_and_stable_block_assignment_and_counts(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);source=root/'source.txt'
            lines=[f'条目 {i}\n'.encode() for i in range(120000)]
            source.write_bytes(b''.join(lines[:3000]+lines[100:200]+lines[3000:]+lines[:10]))
            result=prepare(source,root/'run')
            data=root/'run/data'
            self.assertEqual(result['unique_lines'],120000)
            self.assertEqual(result['duplicate_lines_removed'],110)
            self.assertEqual((data/'deduplicated.txt').read_bytes(),b''.join(lines))
            for name in ('train','heldout'):
                expected=b''.join(line for i,line in enumerate(lines) if block_split(i//1000)==name)
                self.assertEqual((data/(name+'.txt')).read_bytes(),expected)
                self.assertEqual(result['splits'][name]['tokens'],2*result['splits'][name]['lines'])
            with (data/'smoke-train.txt').open() as handle:
                self.assertEqual(sum(1 for _ in handle),100000)
            self.assertEqual(prepare(source,root/'run'),result)
            audited=audit_blocks(root/'run')
            self.assertEqual(audited['blocks_checked'],120)
            self.assertTrue(audited['all_block_routes_byte_equal'])
            with (data/'heldout.txt').open('ab') as output:output.write(lines[0])
            with self.assertRaisesRegex(ValueError,'overlap|Duplicate'):verify_split(data)
            with self.assertRaises(ValueError):audit_blocks(root/'run')

    def test_seed_hash_and_query_metrics_and_requested_configs(self):
        for block in range(1000):
            d=hashlib.sha256(f'kenlm-block-v1:20261105:{block}'.encode()).digest()
            self.assertEqual(block_split(block),'heldout' if int.from_bytes(d[:8],'big')%10000<200 else 'train')
        self.assertEqual(CONFIGS['o4b'],(4,[0,0,0,1]))
        value=parse_query('Perplexity including OOVs: 125.25\nPerplexity excluding OOVs: 110.5\nOOVs: 17\nTokens: 1000\n')
        self.assertEqual(value['oovs'],17)
        with self.assertRaises(ValueError):parse_query('missing summary')

if __name__=='__main__':unittest.main()
