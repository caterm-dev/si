"""Synthetic coverage mining and exclusion guards; no corpora, model or teacher."""
from collections import Counter
import json
import sqlite3
import unittest
from unittest.mock import patch

from llm.reranker_large.scripts import prepare_coverage as coverage
from llm.reranker_small.tokenizer import Tokenizer


class CoverageTests(unittest.TestCase):
    def test_legacy_exact_and_near_queries_are_rejected_without_banning_the_word(self):
        rows=[dict(input='bing',context='给我加两块',references=['冰']),
              dict(input='huoxing',context='这场会议讨论的是新的太空探索计划',references=['火星探测器'])]
        guard=coverage.ExclusionGuard(rows)
        self.assertEqual(guard.reason('bing','给我加两块',['冰','并']),'exact_legacy_query')
        self.assertEqual(guard.reason('huoxing','这场会议讨论的是新太空探索计划',['火星','火刑']),'near_legacy_context')
        self.assertEqual(guard.reason('other','',['这台火星探测器','另一段文本']),'legacy_full_target')
        self.assertIsNone(guard.reason('bing','冷藏果汁适合搭配',['冰','并']))

    def test_pattern_derivation_requires_verified_equal_pronunciation(self):
        class Readings:
            def encode(self,text):return {'冰':'bing','并':'bing','已':'yi','己':'ji'}.get(text)
        overlap=dict(scopes={'native-whole-fusion/contextual':dict(regression_cases={'test':[
            dict(id='a',references=['冰'],distilled=dict(prediction='并')),
            dict(id='b',references=['已'],distilled=dict(prediction='己'))]})})
        families=coverage.patterns_at(overlap,Readings())
        self.assertEqual(len(families),1)
        self.assertEqual(families[0]['spelling'],'bing')
        self.assertEqual(families[0]['diagnostic_origin_ids'],['a'])

    def test_mining_preserves_training_groups_and_pattern_cap(self):
        db=sqlite3.connect(':memory:')
        try:
            db.executescript('CREATE TABLE docs(id TEXT,source TEXT,split TEXT,text TEXT,origin TEXT,grp TEXT,file_key TEXT,priority TEXT); CREATE TABLE readings(text TEXT PRIMARY KEY,spelling TEXT);')
            docs=[('a','public_dialogue','train','果汁里面加了一块冰很好喝','authored','ga','f','a'),
                  ('b','public_dialogue','train','走廊里面装了一枚铃很好看','authored','gb','f','b'),
                  ('c','public_dialogue','validation','不能使用这段冰铃材料','authored','gc','f','c'),
                  ('d','public_dialogue','train','这是旧组里的冰和铃材料','authored','excluded','f','d')]
            db.executemany('INSERT INTO docs VALUES (?,?,?,?,?,?,?,?)',docs)
            chars=set(''.join(d[3] for d in docs)+'并零')
            for c in chars:db.execute('INSERT INTO readings VALUES (?,?)',(c,'bing' if c in '冰并' else 'ling' if c in '铃零' else 'a'))
            db.commit();db.execute('PRAGMA query_only=ON')
            tokenizer=Tokenizer(512,sorted(chars))
            patterns=[dict(id='p1',spelling='bing',variants=['冰','并'],kind='contextual-single-scalar'),
                      dict(id='p2',spelling='ling',variants=['铃','零'],kind='contextual-single-scalar')]
            rows,documents,stats,by_pattern,by_source=coverage.mine(db,patterns,tokenizer,coverage.ExclusionGuard([]),
                {'猫'},{'mao'},set(),{'excluded'},set(),100,1,100,17)
            self.assertEqual(len(rows),2)
            self.assertEqual(by_pattern,{'p1':1,'p2':1})
            self.assertEqual(set(documents),{'a','b'})
            self.assertTrue(all(row['split']=='train' and row['source_group']!='excluded' for row in rows))
            for row in rows:
                doc=documents[row['document_id']]
                self.assertEqual(doc['text'][row['span_start']:row['span_end']],row['observed_text'])
                self.assertEqual(len(row['candidates']),2)
                self.assertFalse(row['teacher_scored'])
                self.assertNotIn('reference_indices',row)
        finally:db.close()

    def test_independent_families_reject_prior_training_spelling(self):
        class Readings:
            def encode(self,text):return 'mao'
        tokenizer=Tokenizer(512,list('猫毛'))
        seeds=dict(families=[dict(id='new',spelling='mao',variants=[dict(text='猫',frames=[]),dict(text='毛',frames=[])])])
        with self.assertRaisesRegex(ValueError,'prior ranking/distillation'):
            coverage.build_validation(seeds,Readings(),tokenizer,coverage.ExclusionGuard([]),{'mao'})

    def test_shared_focus_reading_does_not_override_known_longer_word(self):
        class Readings:
            def encode(self,text):
                return {'':'','拿':'na','那':None,'重要':'zhongyao','重药':'chongyao','要':'yao','药':'yao'}.get(text)
        readings=Readings()
        self.assertEqual(coverage.contrast_spelling(readings,'拿','那','','','na'),'na')
        self.assertIsNone(coverage.contrast_spelling(readings,'重要','重药','','要','zhong'))


if __name__=='__main__':unittest.main()
