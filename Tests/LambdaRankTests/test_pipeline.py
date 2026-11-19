import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pipeline', ROOT / 'scripts/lambdarank/pipeline.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def query(identity, spelling, target, family=None):
    return dict(id=identity, input=spelling, references=[target], context='',
                languages=['zh-Hans', 'en'], family=family or identity, category='synthetic', origin='test')


def candidate(text, label):
    return dict(text=text, language='en', label=label, features=[0.] * len(p.FEATURES))


class PipelineTests(unittest.TestCase):
    def test_starter_splits_do_not_overlap_frozen_test(self):
        counts = p.validate_sets(p.read_rows(p.DATA / 'train.jsonl'),
                                p.read_rows(p.DATA / 'validation.jsonl'),
                                p.read_rows(ROOT / 'eval/ranking/test.jsonl'))
        self.assertGreater(counts['train'], 0)
        self.assertGreater(counts['validation'], 0)
        self.assertEqual(counts['test'], 220)

    def test_reject_alias_family_and_target_leakage(self):
        a, b, c = query('a', "lü'se", '绿色'), query('b', 'hello', 'hello'), query('c', 'world', 'world')
        for field, value in [('input', 'lu:se'), ('family', 'a'), ('references', ['绿色'])]:
            changed = copy.deepcopy(b)
            changed[field] = value
            with self.assertRaisesRegex(ValueError, 'Cross-split'):
                p.validate_sets([a], [changed], [c])

    def test_missing_gold_and_empty_pools_remain_in_denominator(self):
        rows = [dict(id='a', category='x', candidates=[candidate('bad', 0), candidate('good', 1)]),
                dict(id='b', category='x', candidates=[]),
                dict(id='c', category='y', candidates=[candidate('missing', 0)])]
        result = p.metrics(rows)['overall']
        self.assertEqual(result['queries'], 3)
        self.assertEqual(result['pool_recall'], 1/3)
        self.assertEqual(result['mrr'], 1/6)
        self.assertEqual(result['top1'], 0)
        x, y, groups = p.training_matrix(rows)
        self.assertEqual(groups, [2])
        self.assertEqual(y, [0, 1])
        self.assertEqual(len(x), 2)

    def test_rerank_is_stable_and_does_not_mutate_candidates(self):
        class Model:
            def predict(self, x, **kwargs):
                return [1.] * len(x)
        rows = [dict(id='a', category='x', candidates=[candidate('same', 0), candidate('same', 1)])]
        rows[0]['candidates'][1]['language'] = 'zh-Hans'
        before = copy.deepcopy(rows)
        self.assertEqual(p.metrics(rows), p.metrics(rows, Model()))
        self.assertEqual(rows, before)

    def test_export_real_engine_and_hex_round_trip(self):
        binary = ROOT / 'target/release/si-cli'
        if not binary.exists():
            self.skipTest('Build si-cli in Release first')
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'words.csv').write_text('text,reading,weight\n测试,ce\'shi,100\n侧视,ce\'shi,10\n')
            subprocess.run([str(binary), 'lexicon', 'build', str(tmp / 'base.silex'), '0', str(tmp / 'words.csv')], check=True, capture_output=True)
            row = query('a', 'ceshi', '测试')
            row['context'] = '合成前文\n包含\t制表符'
            result = p.export_rows(binary, tmp / 'base.silex', None, [row, query('b', 'unknown', '缺失')])
            self.assertEqual({c['text'] for c in result[0]['candidates']}, {'测试', '侧视'})
            self.assertEqual(sum(c['label'] for c in result[0]['candidates']), 1)
            self.assertEqual(result[1]['candidates'], [])

    def test_correction_export_and_missing_values(self):
        import subprocess
        binary = ROOT / 'target/release/si-cli'
        if not binary.exists():
            self.skipTest('Build si-cli in Release first')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'words.csv').write_text("text,reading,weight\n你好,ni'hao,100\n")
            subprocess.run([str(binary), 'lexicon', 'build', str(tmp / 'base.silex'), '0', str(tmp / 'words.csv')], check=True, capture_output=True)
            row = query('a', 'nihoa', '你好')
            row['languages'] = ['zh-Hans']
            result = p.export_rows(binary, tmp / 'base.silex', None, [row], correction=True)
            features = dict(zip(p.FEATURES, result[0]['candidates'][0]['features']))
            self.assertEqual(features['correction_adjacent_swap'], 1)
            self.assertEqual(features['correction_cost_bits'], 8)
            self.assertEqual(features['is_exact_spelling'], 0)
            self.assertIsNone(features['user_word_hit_ratio'])
            self.assertIsNone(features['at_sentence_start'])
            row['context_available'] = True
            result = p.export_rows(binary, tmp / 'base.silex', None, [row], correction=True)
            features = dict(zip(p.FEATURES, result[0]['candidates'][0]['features']))
            self.assertEqual(features['at_sentence_start'], 1)
            # JSON remains standards-compliant; missing values are null, not NaN.
            json.dumps(result, allow_nan=False)

    def test_v5_exports_completion_path_counts_and_prior_choices(self):
        import subprocess
        binary = ROOT / 'target/release/si-cli'
        if not binary.exists():
            self.skipTest('Build si-cli in Release first')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            base = tmp / 'base.silex'
            (tmp / 'zh.csv').write_text("text,reading,weight\n你好,ni'hao,100\n")
            (tmp / 'en.csv').write_text('text,reading,weight\ncheck,check,100\n'
                                        'good,good,100\nbook,book,100\n')
            subprocess.run([str(binary), 'lexicon', 'build', str(base), '0', str(tmp / 'zh.csv'),
                            '1', str(tmp / 'en.csv')], check=True, capture_output=True)
            completion = query('a', 'chec', 'check')
            completion['languages'] = ['en']
            completion['prior_choices'] = [{'text': 'check', 'language': 'en', 'bonus': 2}]
            abbreviation = query('b', 'nh', '你好')
            composed = query('c', 'goodbook', 'good book')
            composed['prior_choices'] = [
                {'text': 'book', 'language': 'en', 'token_spelling': 'book', 'bonus': 6},
            ]
            rows = p.export_rows(binary, base, None, [completion, abbreviation, composed], p.V5_LEXICAL_SCHEMA)

            def observed(row, text):
                result = next(candidate for candidate in rows[row]['candidates'] if candidate['text'] == text)
                return dict(zip(p.V5_LEXICAL_FEATURES, result['features'], strict=True))

            f = observed(0, 'check')
            self.assertEqual((f['is_completion'], f['completion_missing_letters'], f['has_exact_dictionary_match']), (1, 1, 0))
            self.assertEqual(f['user_choice_whole_bonus'], 2)
            self.assertEqual(f['english_token_count'], 1)
            self.assertEqual(f['base_gram_available'], 0)
            self.assertIsNone(f['field_context_adjustment_bits'])
            self.assertEqual(p.export_rows(binary, base, None, [completion])[0]['candidates'], [])
            f = observed(1, '你好')
            self.assertEqual((f['abbreviated_token_count'], f['abbreviated_syllable_count']), (1, 2))
            self.assertIsNone(f['user_choice_whole_bonus'])
            f = observed(2, 'good book')
            self.assertEqual((f['english_token_count'], f['user_choice_token_bonus']), (2, 3))
            self.assertEqual(f['user_choice_whole_bonus'], 0)

    def test_feature_ablation_preserves_candidates_labels_and_legacy_columns(self):
        rows = [dict(id='a', category='x', candidates=[candidate('first', 0), candidate('second', 1)])]
        for row in rows[0]['candidates']:
            row['features'] = list(range(len(p.FEATURES)))
        original = copy.deepcopy(rows)
        legacy, names = p.select_features(rows, p.V2_FEATURES, 'v1')
        self.assertEqual(names, p.V1_FEATURES)
        self.assertEqual(legacy[0]['candidates'][0]['features'], list(range(12)))
        for selection in ['all', 'without_user', *('without_' + name for name in p.FEATURE_GROUPS)]:
            projected, names = p.select_features(rows, p.FEATURES, selection)
            self.assertEqual([c['label'] for c in projected[0]['candidates']], [0, 1])
            self.assertEqual([c['text'] for c in projected[0]['candidates']], ['first', 'second'])
            self.assertEqual(projected[0]['candidates'][0]['features'], [p.FEATURES.index(name) for name in names])
        self.assertEqual(original, rows)
        with self.assertRaisesRegex(ValueError, 'incompatible'):
            p.select_features(legacy, p.V1_FEATURES, 'add_spelling')

    def test_neural_pool_preserves_identities_and_scores_generated_only_candidates(self):
        row = query('a', 'fangan', '方案')
        row['context'] = '先定个'
        row['candidates'] = [candidate('方案', 1), candidate('放案', 0), candidate('find', 0),
                             candidate('方案', 1)]
        row['candidates'][0]['language'] = 'zh-Hans'
        row['candidates'][1]['language'] = 'zh-Hans'
        row['candidates'][3]['language'] = 'mixed'

        def generate(spelling, context, syllables):
            self.assertEqual((spelling, context, syllables), ('fangan', '先定个', ()))
            return ['方案', '反感', 'fangan', '方案', '有\n控制符']

        def score(context, texts):
            self.assertEqual(context, '先定个')
            self.assertEqual(texts, ['方案', '放案', 'find', '反感'])
            return {text: (-i, -i / 2, 0.5) for i, text in enumerate(texts)}

        merged = p.neural_features.merge_row(row, p.FEATURES, generate, score)
        features = [dict(zip(p.NEURAL_FEATURES, c['features'], strict=True)) for c in merged['candidates']]
        self.assertEqual(len(row['candidates']), 4)
        self.assertEqual([f['from_si_engine'] for f in features], [1, 1, 1, 1, 0])
        self.assertEqual([f['pinyin_model_beam_rank'] for f in features], [1, None, None, None, 2])
        self.assertEqual([c['label'] for c in merged['candidates']], [1, 0, 0, 1, 0])
        self.assertEqual(features[0]['reranker_logp_sum'], features[3]['reranker_logp_sum'])
        self.assertIsNone(features[-1]['unigram_logp_sum'])
        self.assertEqual(features[-1]['candidate_language'], 0)
        self.assertEqual(features[-1]['reranker_logp_sum'], -3)
        projected, names = p.select_features([merged], p.NEURAL_FEATURES, 'without_neural')
        self.assertEqual(names, p.FEATURES)
        self.assertEqual(len(projected[0]['candidates']), 5)

    def test_neural_scoring_keeps_one_context_window_and_marks_overflow_missing(self):
        scorer = object.__new__(p.neural_features.NeuralModels)
        scorer.reranker = type('Model', (), {'config': {'context': 3}})()
        scorer.reranker_tokenizer = type('Tokenizer', (), {'encode': lambda _, text: [0, *text, 1]})()
        scorer.reranker_settings = {'batch_size': 2}
        scorer.device = 'cpu'
        scorer.beam_size = 8

        def rank(model, tokenizer, context, eligible, device, **kwargs):
            self.assertEqual(eligible, ['一', '二字'])
            self.assertEqual(kwargs['max_candidates'], 72)
            return {'scores': [-2.0, -6.0] if context else [-3.0, -5.0]}

        scorer.rank = rank
        self.assertEqual(scorer.score('前文', ['一', '二字', '超出长度']), {
            '一': (-2.0, -2.0, 1.0), '二字': (-6.0, -3.0, -1.0), '超出长度': (None, None, None)})
        self.assertEqual(scorer.score(None, ['一', '二字'])['一'], (-3.0, -3.0, None))

    def test_aliases_can_share_a_training_family(self):
        first = query('a', 'lüse', '绿色', 'green')
        alias = query('b', 'lu:se', '绿色', 'green')
        validation = query('c', 'hello', 'hello')
        test = query('d', 'world', 'world')
        p.validate_sets([first, alias], [validation], [test])
        duplicate = copy.deepcopy(first)
        duplicate['id'] = 'another'
        with self.assertRaisesRegex(ValueError, 'duplicate query'):
            p.validate_sets([first, duplicate], [validation], [test])

    def test_bundle_tampering_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ['train.jsonl', 'validation.jsonl']:
                (root / name).write_text('{}\n')
            p.write_json(root / 'manifest.json', dict(schema=p.SCHEMA, features=p.FEATURES,
                         files={name: p.sha(root / name) for name in ['train.jsonl', 'validation.jsonl']}))
            (root / 'train.jsonl').write_text('{"changed":true}\n')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                p.load_bundle(root)


if __name__ == '__main__':
    unittest.main()
