"""End-to-end raw-text lineage and complete-sentence preservation fixtures."""

import gzip
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_raw_text import extract
from prepare_kenlm_raw import tokenize_source, verify_source, finalize, normalize_for_verification
from tokenize_unigram import load_dictionary, normalize_line


class RawKenLMPreparationTests(unittest.TestCase):
    def test_finalization_rejects_sources_using_different_dictionaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = [{'id': 'one'}, {'id': 'two'}]
            for source, checksum in zip(sources, ('a' * 64, 'b' * 64), strict=True):
                folder = root / source['id']
                folder.mkdir()
                (folder / 'manifest.json').write_text(json.dumps({
                    'identity': {'dictionary_sha256': checksum}}))
            with self.assertRaisesRegex(ValueError, 'different unigram dictionaries'):
                finalize(sources, root / 'inputs', root)
            self.assertFalse((root / 'kenlm-input.txt').exists())

    def test_independent_normalization_agrees_for_every_unicode_code_point_and_compositions(self):
        text = ''.join(map(chr, range(0x110000))) + 'A\u030a\t１２.５０\u200b中\u034f文\u2028co-op\u200d'
        self.assertEqual(normalize_for_verification(text), normalize_line(text))

    def test_raw_to_existing_tokenizer_retains_year_commas_short_spans_and_origins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.gz'
            text = '组织推选2017年，甲、乙。English co-op 12.50！\n' + 'a ' * 100 + '？末尾。'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps({'text': text}) + '\n')
            source = {'id': 'fixture', 'kind': 'mc4'}
            input_root, output_root = root / 'inputs', root / 'outputs'
            input_root.mkdir()
            extract(source, archive, input_root / 'fixture')
            dictionary = root / 'dictionary.csv'
            dictionary.write_text('text,count\n组织,20\n推选,20\n年,10\n末尾,10\n')
            record = tokenize_source(source, input_root, output_root, dictionary, 2)
            lines = (output_root / 'fixture/text.txt').read_text().splitlines()
            self.assertEqual(lines, ['组织 推选 2017 年 , 甲 、 乙 。',
                                     'english co-op 12.50 !', '末尾 。'])
            self.assertEqual([json.loads(line) for line in (output_root / 'fixture/origins.jsonl').read_text().splitlines()],
                             [[1, 1], [1, 2], [2, 2]])
            self.assertEqual(record['counts']['over_100_tokens'], 1)
            self.assertEqual(record['counts']['sentences_with_digits'], 2)
            self.assertEqual(tokenize_source(source, input_root, output_root, dictionary, 2), record)
            manifest = finalize([source], input_root, output_root)
            self.assertEqual((output_root / 'kenlm-input.txt').read_text(), '\n'.join(lines) + '\n')
            self.assertEqual(manifest['totals']['sentences'], 3)
            self.assertFalse(manifest['training_started'])
            path = output_root / 'fixture/text.txt'
            path.write_text(path.read_text().replace('2017 ', '', 1))
            with self.assertRaisesRegex(ValueError, 'characters, numbers or punctuation'):
                verify_source(input_root / 'fixture/text.txt', path, output_root / 'fixture/origins.jsonl',
                              load_dictionary(dictionary))

    def test_verifier_rejects_unexplained_sentence_loss_and_extra_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output, origins = root / 'source.txt', root / 'out.txt', root / 'origins.jsonl'
            dictionary = root / 'dict.csv'
            dictionary.write_text('text,count\n甲,1\n')
            source.write_text('甲2017。\n')
            output.write_text('')
            origins.write_text('')
            with self.assertRaisesRegex(ValueError, 'lost'):
                verify_source(source, output, origins, load_dictionary(dictionary))
            output.write_text('甲 2017 。\n甲 。\n')
            origins.write_text('[1,1]\n[2,1]\n')
            with self.assertRaisesRegex(ValueError, 'unmatched extra'):
                verify_source(source, output, origins, load_dictionary(dictionary))


if __name__ == '__main__':
    unittest.main()
