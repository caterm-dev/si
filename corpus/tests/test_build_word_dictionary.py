"""Word-side vocabulary selection excludes phrase sources and ranking weights."""
import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_word_dictionary import build
from tokenize_unigram import load_dictionary


class WordDictionaryTests(unittest.TestCase):
    def test_only_flat_words_supply_vocabulary_and_corpus_counts_supply_scores(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            words = root / 'chinese'
            (words / 'phrase').mkdir(parents=True)
            (words / 'base.csv').write_text("text,reading,weight\n根据,gen'ju,99999\n材料,cai'liao,0\n长春,chang'chun,10\n未见词,wei'jian'ci,98765\n")
            (words / 'phrase/base.csv').write_text("text,reading,weight\n根据材料,gen'ju'cai'liao,999999\n长春,chang'chun,999999\n")
            frequency = root / 'counts.csv'
            frequency.write_text('text,count\n根据,30\n材料,20\n长春,15\n根据材料,100000\n额外,10\n')
            result = build(words, frequency, root / 'output')
            with (root / 'output/frequencies.csv').open() as handle:
                counts = {row['text']: int(row['count']) for row in csv.DictReader(handle)}
            self.assertEqual(counts, {'根据':30, '材料':20, '长春':15, '未见词':1})
            self.assertEqual(result['smoothed_words'], 1)
            self.assertEqual(load_dictionary(root / 'output/frequencies.csv').segment('根据材料'), ['根据','材料'])
            self.assertNotIn(str(words / 'phrase/base.csv'), result['sources'])
            self.assertEqual(json.loads((root / 'output/manifest.json').read_text())['words'],4)
            self.assertEqual(build(words, frequency, root / 'output'), result)
            (words / 'phrase/base.csv').write_text('Excluded data may change without affecting the dictionary')
            self.assertEqual(build(words, frequency, root / 'output'), result)
            (words / 'base.csv').write_text("text,reading,weight\n改变,gai'bian,10\n")
            with self.assertRaisesRegex(ValueError, 'different inputs'):
                build(words, frequency, root / 'output')
