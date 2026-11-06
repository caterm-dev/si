"""Synthetic normalization, Viterbi, streaming and spawned-worker regressions."""

import csv
import io
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tokenize_unigram import (MAX_WORDS, UnigramDictionary, line_chunks, load_dictionary,
                              normalize_line, sentences, tokenize_sentence)

SCRIPT = Path(__file__).resolve().parents[1] / 'tokenize_unigram.py'


class UnigramTokenizerTests(unittest.TestCase):
    def setUp(self):
        self.dictionary = UnigramDictionary.from_counts({
            '你好': 100, '世界': 80, '研究': 100, '研究生': 1, '生命': 100, '命': 1, '起源': 100,
        })

    def test_nfkc_controls_fillers_and_invisible_selectors(self):
        value = '\ufeffＡ\u200bＢ\x00Ｃ\tＤ\u034f\ufe0f\U000e0100\u3164\u2800\u202e\x7f'
        self.assertEqual(normalize_line(value), 'ABC D')
        self.assertEqual(normalize_line('Hello\tWorld\u00a0Again'), 'Hello World Again')
        self.assertEqual(normalize_line('神\r\n'), '神  ')
        self.assertEqual(normalize_line('é'), 'é')

    def test_sentence_boundaries_protect_decimals_and_english_words(self):
        value = normalize_line("你好，World! Don't co-operate at １２.５０;世界。Tail")
        self.assertEqual(list(sentences(value)), [
            '你好,', 'World!', "Don't co-operate at 12.50;", '世界。', 'Tail',
        ])
        self.assertEqual(list(sentences('Price 3.14. Next 2.0?')), ['Price 3.14.', 'Next 2.0?'])
        self.assertEqual(list(sentences('你好、世界:结束')), ['你好、', '世界:', '结束'])
        self.assertEqual(list(sentences('你好,世界。', frozenset('。'))), ['你好,世界。'])

    def test_punctuation_clusters_and_closing_quotes_stay_with_the_sentence(self):
        self.assertEqual(list(sentences('“你好？！”接着说。')), ['“你好？！”', '接着说。'])
        self.assertEqual(list(sentences('"Hello!" "World?"')), ['"Hello!"', '"World?"'])
        self.assertEqual(list(sentences(normalize_line('  你好...  世界；；  '))), ['你好...', '世界;;'])
        self.assertEqual(list(sentences('  \t  ')), [])

    def test_viterbi_uses_the_globally_best_path_instead_of_longest_match(self):
        self.assertEqual(self.dictionary.segment('研究生命起源'), ['研究', '生命', '起源'])
        self.assertEqual(self.dictionary.segment('你好未知世界'), ['你好', '未', '知', '世界'])
        self.assertEqual(self.dictionary.segment(''), [])
        total = 482
        self.assertAlmostEqual(self.dictionary.log_probabilities['研究'], math.log(100 / total))
        self.assertEqual(self.dictionary.unknown_log_probability,
                         min(self.dictionary.log_probabilities.values()) - 5)
        self.assertEqual(self.dictionary.max_word_length, 3)

    def test_ties_are_deterministic_and_prefer_the_longer_first_word(self):
        counts = {'甲': 3, '乙': 3, '甲乙': 1, '丙': 2}
        first = UnigramDictionary.from_counts(counts)
        second = UnigramDictionary.from_counts(dict(reversed(list(counts.items()))))
        self.assertEqual(first.segment('甲乙'), ['甲乙'])
        self.assertEqual(second.segment('甲乙'), ['甲乙'])

    def test_fragment_grammar_case_numbers_symbols_and_no_reserved_tokens(self):
        value = normalize_line("你好Don't CO-OPERATE １２.５０ ١٢.٥ _ 😀 𠮷 café <s> </s> <unk>")
        self.assertEqual(tokenize_sentence(value, self.dictionary), [
            '你好', "don't", 'co-operate', '12.50', '١٢.٥', '_', '😀', '𠮷', 'caf', 'é',
            '<', 's', '>', '<', '/', 's', '>', '<', 'unk', '>',
        ])

    def test_token_limit_is_inclusive_and_counts_punctuation(self):
        self.assertEqual(len(tokenize_sentence('甲' * MAX_WORDS, self.dictionary)), 100)
        self.assertIsNone(tokenize_sentence('甲' * (MAX_WORDS + 1), self.dictionary))
        self.assertEqual(len(tokenize_sentence('a ' * 99 + '.', self.dictionary)), 100)
        self.assertIsNone(tokenize_sentence('a ' * 100 + '.', self.dictionary))
        long_word = '汉' * 120
        dictionary = UnigramDictionary.from_counts({long_word: 1})
        self.assertEqual(dictionary.max_word_length, 120)
        self.assertEqual(tokenize_sentence(long_word + '。', dictionary), [long_word, '。'])
        self.assertIsNone(tokenize_sentence('汉' * 12001, dictionary))
        clauses = list(sentences('a ' * 80 + ', ' + 'b ' * 80 + '.'))
        self.assertEqual(len(clauses), 2)
        self.assertEqual([len(tokenize_sentence(part, self.dictionary)) for part in clauses], [81, 81])

    def test_dictionary_formats_normalization_duplicate_counts_and_weight_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'counts.csv'
            path.write_text('\ufefftext,count,other\n神,2,x\n神,3,x\n你好,5,x\nWorld,1000,x\n零,0,x\n')
            dictionary = load_dictionary(path)
            self.assertEqual(set(dictionary.log_probabilities), {'神', '你好'})
            self.assertAlmostEqual(dictionary.log_probabilities['神'], math.log(0.5))
            for name, contents in [('plain.txt', '# Synthetic\n研究 3\n生命 2\n'),
                                   ('table.tsv', 'word\tfreq\n研究\t3\n生命\t2\n'),
                                   ('pairs.csv', '研究,3\n生命,2\n')]:
                target = root / name
                target.write_text(contents)
                self.assertEqual(set(load_dictionary(target).log_probabilities), {'研究', '生命'})
            path.write_text('text 5\nword 8\n你好 1\n')
            self.assertEqual(set(load_dictionary(path).log_probabilities), {'你好'})
            for contents in ('text,reading,weight\n你好,nihao,10\n', 'text,count\n你好,-1\n',
                             '你好 nan\n', '你好 1.5\n', '你好\n', 'World 1\n', ''):
                path.write_text(contents)
                with self.subTest(contents=contents), self.assertRaises(ValueError):
                    load_dictionary(path)

    def test_line_chunking_has_a_byte_bound_and_only_one_line_of_lookahead(self):
        source = io.BytesIO(b'first\nsecond\nthird\nlast')
        chunks = line_chunks(source, 1000, 12)
        self.assertEqual(next(chunks), (1, (b'first\n',)))
        self.assertLess(source.tell(), len(source.getvalue()))
        self.assertEqual(list(chunks), [(2, (b'second\n',)), (3, (b'third\n', b'last'))])
        self.assertEqual(list(line_chunks(io.BytesIO(b'abcdef\nx\n'), 2, 2)),
                         [(1, (b'abcdef\n',)), (2, (b'x\n',))])


class UnigramTokenizerCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dictionary = self.root / 'dictionary.csv'
        with self.dictionary.open('w', newline='') as handle:
            writer = csv.writer(handle)
            writer.writerow(['text', 'count'])
            writer.writerows([('你好', 10), ('世界', 10), ('研究', 10), ('生命', 10), ('起源', 10)])
        self.input = self.root / 'input.txt'

    def command(self, output, workers=2, extra=()):
        return subprocess.run([
            sys.executable, str(SCRIPT), '--input', str(self.input), '--output', str(output),
            '--dictionary', str(self.dictionary), '--workers', str(workers),
            '--chunk-lines', '2', '--chunk-bytes', '256', '--max-in-flight', '2', *extra,
        ], capture_output=True, text=True, timeout=60)

    def test_spawned_workers_preserve_order_and_exact_output_format(self):
        source = ("\ufeff你好，WORLD! Don't co-operate １２.５０。\n\n\u200b\x00\n"
                  + 'a ' * 100 + '.\n' + 'a ' * 99 + '.\n'
                  + '研究生命起源。未知𠮷😀\n' + 'Tail')
        self.input.write_text(source, encoding='utf-8')
        outputs = []
        for workers in (1, 2):
            path = self.root / f'out-{workers}.txt'
            origins = self.root / f'origins-{workers}.jsonl'
            result = self.command(path, workers, extra=('--output-origins', str(origins)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertIn('100.00%', result.stderr)
            self.assertIn('1 over 100 tokens', result.stderr)
            outputs.append(path.read_bytes())
            self.assertEqual([json.loads(line) for line in origins.read_text().splitlines()],
                             [[1, 1], [1, 2], [1, 3], [5, 1], [6, 1], [6, 2], [7, 1]])
        self.assertEqual(outputs[0], outputs[1])
        lines = outputs[0].decode('utf-8').splitlines()
        self.assertEqual(lines[:3], ['你好 ,', 'world !', "don't co-operate 12.50 。"])
        self.assertEqual(lines[-3:], ['研究 生命 起源 。', '未 知 𠮷 😀', 'tail'])
        self.assertEqual(len(lines[3].split()), 100)
        for line in lines:
            self.assertTrue(line)
            self.assertEqual(line, line.strip())
            self.assertNotIn('  ', line)
            self.assertNotIn('\t', line)
            self.assertNotIn('\r', line)
            self.assertTrue(set(line.split()).isdisjoint({'<s>', '</s>', '<unk>'}))
        self.assertTrue(outputs[0].endswith(b'\n'))

    def test_decode_error_preserves_existing_files_and_leaves_no_partial_output(self):
        self.input.write_bytes('你好。\n世界。\n'.encode() + b'\xff\n')
        output = self.root / 'new.txt'
        origins = self.root / 'new-origins.jsonl'
        result = self.command(output, extra=('--output-origins', str(origins)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('line 3', result.stderr)
        self.assertFalse(output.exists())
        self.assertEqual(list(self.root.glob('.new.txt-*')), [])
        self.assertFalse(origins.exists())
        self.assertEqual(list(self.root.glob('.new-origins.jsonl-*')), [])
        output.write_text('Retain existing output\n')
        result = self.command(output)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), 'Retain existing output\n')

    def test_origin_path_conflicts_preserve_all_existing_files(self):
        self.input.write_text('你好。\n')
        output = self.root / 'new.txt'
        origins = self.root / 'existing.jsonl'
        origins.write_text('Retain original map\n')
        result = self.command(output, extra=('--output-origins', str(origins)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertEqual(origins.read_text(), 'Retain original map\n')
        result = self.command(output, extra=('--output-origins', str(output)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_empty_input_and_invalid_parallel_arguments(self):
        self.input.write_text('')
        output = self.root / 'empty.txt'
        result = self.command(output, extra=('--quiet',))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b'')
        self.assertEqual(result.stdout + result.stderr, '')
        result = self.command(self.root / 'invalid.txt', extra=('--chunk-lines', '0'))
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'invalid.txt').exists())


if __name__ == '__main__':
    unittest.main()
