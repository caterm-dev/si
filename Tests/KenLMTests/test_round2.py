import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
import kenlm_round2 as r

class Round2Tests(unittest.TestCase):
    def test_raw_occurrence_counts_and_special_token_denominator(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);old=root/'old';data=old/'data';data.mkdir(parents=True)
            (data/'train.txt').write_text('1234 乙 丙\n'+'乙 丙\n'*4+'丙\n')
            (data/'heldout.txt').write_text('丙\n')
            splits={name:{'sha256':hashlib.sha256((data/(name+'.txt')).read_bytes()).hexdigest()} for name in ('train','heldout')}
            (data/'manifest.json').write_text(json.dumps({'splits':splits}))
            out=root/'new';arpa=out/'o4a-unquantized/model.arpa';arpa.parent.mkdir(parents=True)
            arpa.write_text('\\data\\\nngram 1=6\nngram 2=1\n\\1-grams:\n'+''.join('-9.9 '+w+' -0.2\n' for w in ('<s>','</s>','<unk>','1234','乙','丙'))+'\\2-grams:\n')
            with patch.object(r,'OLD',old):r.vocabulary(out)
            stats=json.loads((out/'vocabulary/statistics.json').read_text())
            self.assertEqual(stats['arpa_vocabulary_including_specials'],6)
            self.assertEqual(stats['lexical_vocabulary'],3)
            self.assertEqual(stats['once'],1)
            self.assertEqual(stats['at_most_five'],2)
            self.assertEqual(stats['train_tokens'],12)
            self.assertEqual(stats['once_fraction'],1/3)
            self.assertEqual(stats['top30'][0]['word'],'1234')

    def test_exact_requested_grid_and_arpa_header(self):
        self.assertEqual(r.NEW,{'o5c':(5,[0,0,1,2,3]),'o4d':(4,[0,1,2,3]),'o4e':(4,[0,0,2,3]),'o3b':(3,[0,1,2])})
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'model.arpa'
            p.write_text('\\data\\\nngram 1=5\nngram 2=3\n\n\\1-grams:\n-1 测试 -0.2\n')
            header,counts=r.arpa_header(p)
            self.assertEqual(counts,{'1':5,'2':3})
            self.assertTrue(header.endswith('\\1-grams:\n'))

    def test_noise_flags_are_candidates_and_long_boundary_is_explicit(self):
        self.assertEqual(r.noise_reasons('2026'),['pure_digits'])
        self.assertEqual(r.noise_reasons('12.50'),['numeric_form'])
        self.assertIn('garbled_or_nonprinting',r.noise_reasons('\ufffd'))
        self.assertIn('garbled_or_nonprinting',r.noise_reasons('\ue000'))
        self.assertEqual(r.noise_reasons('a'*32),[])
        self.assertEqual(r.noise_reasons('a'*33),['long_token'])
        self.assertEqual(r.noise_reasons('完整专业术语'),[])

    def test_runtime_preserves_raw_output_and_uses_native_darwin_bytes(self):
        text='query\t1048576\t1000000\tRSSMax:1048576 kB\tuser:1\tsys:0.5\tCPU:1.5\treal:2.0\n'
        with patch.object(r.sys,'platform','darwin'):
            value=r.parse_runtime(text)
        self.assertEqual(value['rssmax_bytes'],1048576)
        self.assertEqual(value['query_cpu_seconds'],1.5)
        self.assertEqual(value['query_real_seconds'],2)
        with self.assertRaises(ValueError):r.parse_runtime('incomplete')

    def test_input_pin_is_read_only_and_detects_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);old=root/'old';data=old/'data';data.mkdir(parents=True)
            splits={}
            for name in ('train','heldout'):
                p=data/(name+'.txt');p.write_bytes(name.encode()+b'\n');splits[name]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
            (data/'manifest.json').write_text(json.dumps({'splits':splits}))
            before={p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in data.iterdir()}
            with patch.object(r,'OLD',old):
                r.pin_inputs(root/'new');r.pin_inputs(root/'new')
                self.assertEqual(before,{p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in data.iterdir()})
                (data/'train.txt').write_bytes(b'altered\n')
                with self.assertRaises(ValueError):r.pin_inputs(root/'new')

if __name__=='__main__':unittest.main()
