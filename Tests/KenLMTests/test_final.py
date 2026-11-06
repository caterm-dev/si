from collections import Counter
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
import kenlm_final as f


class FinalBuildTests(unittest.TestCase):
    def test_full_counts_cross_rare_threshold_without_resplitting(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);train=root/'train.txt';heldout=root/'heldout.txt';merged=root/'full.raw.txt'
            train.write_text('新词 1 字典\n'*4+'整行 � 删除\n'+'x'*33+' 7\n')
            heldout.write_text('新词 2 字典\n'+'稀少 字典\n'+'坏 锟斤拷\n')
            original={p:p.read_bytes() for p in (train,heldout)}
            counts,parts,sha=f.merge_and_count((train,heldout),merged)
            self.assertEqual(merged.read_bytes(),original[train]+original[heldout])
            self.assertEqual(f.previous.digest(merged),sha)
            self.assertEqual(counts['新词'.encode()],5)
            mapping,output,replacements=f.make_mapping(counts,{'字典'})
            self.assertEqual(mapping['新词'.encode()],('新词'.encode(),None))
            self.assertEqual(mapping['稀少'.encode()],(b'<oov>','rare'))
            self.assertEqual(mapping[b'x'*33],(b'<oov>','long'))
            self.assertEqual(output[b'<num>'],6)
            self.assertEqual(replacements,Counter({'numeric':6,'rare':1,'long':1}))
            self.assertEqual(sum(p['deleted_garbled_lines'] for p in parts),2)
            for path,raw in original.items():self.assertEqual(path.read_bytes(),raw)

    def test_same_length_token_matched_bad_control(self):
        good=['我','今天','早上','坐','地铁','去','公司','。']
        bad=f.reversed_pair(good)
        self.assertEqual(Counter(good),Counter(bad))
        self.assertEqual(bad[-1],'。')
        self.assertNotEqual(good,bad)
        short=['请','你帮我把','窗户','关上','。']
        self.assertEqual(f.reversed_pair(short),['关上','窗户','你帮我把','请','。'])
        with self.assertRaises(ValueError):f.reversed_pair(['太','短','。'])
        fixture=json.loads(f.FIXTURE.read_text())
        self.assertEqual(len(fixture['good_sentences']),20)
        self.assertEqual(fixture['acceptance_before_scoring']['required_pair_wins'],20)

    def test_sentence_scores_require_complete_output(self):
        rows=f.parse_sentence_scores('Total: -12.5 OOV: 0\nTotal: -2e1 OOV: 0\n',2)
        self.assertEqual(rows,[{'log10_probability':-12.5,'oovs':0},{'log10_probability':-20.,'oovs':0}])
        with self.assertRaises(ValueError):f.parse_sentence_scores('Total: -12.5 OOV: 0\n',2)

    def test_fingerprint_is_canonical_and_sensitive_to_contract(self):
        self.assertEqual(f.canonical_sha({'规则':1,'threshold':5}),f.canonical_sha({'threshold':5,'规则':1}))
        self.assertNotEqual(f.canonical_sha({'threshold':5}),f.canonical_sha({'threshold':20}))

    def test_arpa_markers_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'test.arpa'
            path.write_text('\\data\\\nngram 1=2\n\\1-grams:\n-1 <num>\n-1 <oov>\n\\2-grams:\n')
            self.assertEqual(f.arpa_vocabulary(path),2)
            path.write_text('\\data\\\nngram 1=1\n\\1-grams:\n-1 <num>\n\\2-grams:\n')
            with self.assertRaises(ValueError):f.arpa_vocabulary(path)


if __name__=='__main__':unittest.main()
