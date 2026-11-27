"""Unused-batch regressions on authored miniature corpus snapshots only."""

from collections import Counter
import contextlib
import io
from pathlib import Path
import sqlite3
import tempfile
import unittest

from llm.reranker_large.corpus_data import assigned_split, prepare_corpus
from llm.reranker_large.scripts.prepare_extra_data import (
    create_index, paragraphs, prepare, select_unused,
)
from llm.reranker_large.settings import code_identity, fingerprint, load_config, read_json
from llm.reranker_large.tests.test_corpus import fixture, save_snapshot
from llm.reranker_small.data import load_bundle
from llm.reranker_small.tokenizer import Tokenizer
from llm.pinyin_to_text.common import normalized, read_jsonl


class ExtraCorpusTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='si-extra-corpus-test-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.config, self.mixture, self.raw, self.notices = fixture(self.root / 'input')
        self.parent = self.root / 'parent'
        with contextlib.redirect_stdout(io.StringIO()):
            prepare_corpus(self.config, self.mixture, self.raw, self.notices, self.parent)

    def run_prepare(self, name='extra', budget=50):
        with contextlib.redirect_stdout(io.StringIO()):
            return prepare(self.config, self.mixture, self.raw, self.notices,
                           self.parent, self.root / name, train_tokens=budget)

    def test_frozen_tokenizer_disjoint_groups_documents_paragraphs_and_windows(self):
        before = code_identity()
        result = self.run_prepare()
        self.assertEqual(before, code_identity())
        output = self.root / 'extra'
        self.assertEqual((self.parent / 'tokenizer.json').read_bytes(), (output / 'tokenizer.json').read_bytes())
        self.assertEqual(result['tokenizer_origin'], 'frozen-parent')
        parent_groups, parent_ids, prior_paragraphs = set(), set(), set()
        for split in ('train', 'validation', 'test'):
            for row in read_jsonl(self.parent / f'{split}.documents.jsonl'):
                parent_groups.add((row['source'], row['group']))
                parent_ids.add(row['id'])
                prior_paragraphs.update(paragraphs(row['text']))
        _, tokenizer, datasets = load_bundle(output, load_config(self.config), ('train', 'validation', 'test'))
        seen = {}
        for split, dataset in datasets.items():
            target_sum = 0
            encoded = []
            for row in read_jsonl(output / f'{split}.documents.jsonl'):
                self.assertNotIn((row['source'], row['group']), parent_groups)
                self.assertNotIn(row['id'], parent_ids)
                self.assertFalse(paragraphs(row['text']) & prior_paragraphs)
                for key in paragraphs(row['text']):
                    self.assertEqual(seen.setdefault(key, split), split)
                ids = tokenizer.encode(row['text'])
                encoded.extend(ids)
                target_sum += len(ids)-1
            self.assertEqual(dataset.tokens.tolist(), encoded)
            self.assertEqual(sum(int(w[1])-1 for w in dataset.windows), target_sum)
            self.assertEqual(target_sum, result['splits'][split]['targets'])
        self.assertGreaterEqual(result['splits']['train']['targets'], 50)
        self.assertGreater(result['selection_counts']['excluded_prior_documents_or_groups'], 0)
        again = self.run_prepare(name='again')
        self.assertEqual(result['dataset_id'], again['dataset_id'])

    def test_shortfall_and_existing_output_do_not_reuse_or_overwrite(self):
        with self.assertRaisesRegex(ValueError, 'Insufficient unused'):
            self.run_prepare(budget=1000000)
        self.assertFalse((self.root / 'extra').exists())
        result = self.run_prepare()
        with self.assertRaises(FileExistsError):
            self.run_prepare()
        self.assertEqual(read_json(self.root / 'extra/manifest.json')['dataset_id'], result['dataset_id'])

    def test_corrupt_parent_documents_rejected(self):
        with (self.parent / 'validation.documents.jsonl').open('a') as stream:
            stream.write('{}\n')
        with self.assertRaisesRegex(ValueError, 'modified'):
            self.run_prepare()
        self.assertFalse((self.root / 'extra').exists())

    def test_additional_excluded_batch_is_not_reused(self):
        self.run_prepare()
        with contextlib.redirect_stdout(io.StringIO()):
            result = prepare(self.config, self.mixture, self.raw, self.notices, self.parent,
                             self.root / 'third', train_tokens=50, exclude_data=[self.root / 'extra'])
        excluded_groups = set()
        for root in (self.parent, self.root / 'extra'):
            for split in ('train', 'validation', 'test'):
                excluded_groups.update((r['source'], r['group'])
                    for r in read_jsonl(root / f'{split}.documents.jsonl'))
        for split in ('train', 'validation', 'test'):
            for row in read_jsonl(self.root / 'third' / f'{split}.documents.jsonl'):
                self.assertNotIn((row['source'], row['group']), excluded_groups)
        self.assertEqual(len(result['excluded_dataset_ids']), 2)

    def shortfall_selection(self, name, *, allow=False, empty_test=False, train_short=False):
        connection = sqlite3.connect(':memory:')
        self.addCleanup(connection.close)
        create_index(connection)
        for split in ('train', 'validation', 'test'):
            if empty_test and split == 'test':
                continue
            for category, source in [('dialogue', 'lccc'), ('wikipedia', 'wikipedia'), ('technical', 'mdn')]:
                text = split + category + ' synthetic unique text ' * 30
                if category == 'technical' and (split != 'train' or train_short):
                    text = {'test': 'T', 'validation': 'V', 'train': 'R'}[split]
                group = split + '/' + category
                connection.execute('INSERT INTO docs VALUES (?,?,?,?,?,?,?,?,?)',
                    (fingerprint(normalized(text)), source, group, split, category, '0', group, text, None))
        mixture = read_json(self.mixture)
        audit = self.root / name
        audit.mkdir()
        with contextlib.redirect_stdout(io.StringIO()):
            selection, _ = select_unused(connection, load_config(self.config), mixture,
                Tokenizer(300, []), audit, Counter(), allow_heldout_shortfall=allow)
        return selection

    def test_heldout_shortfalls_require_explicit_option_and_keep_train_quotas(self):
        with self.assertRaisesRegex(ValueError, 'test/technical.*allow-heldout-shortfall'):
            self.shortfall_selection('strict')
        selection = self.shortfall_selection('allowed', allow=True)
        for split in ('test', 'validation'):
            self.assertEqual(selection[split]['technical']['actual_targets'], 2)
            self.assertGreater(selection[split]['technical']['shortfall_targets'], 0)
        for values in selection['train'].values():
            self.assertGreaterEqual(values['actual_targets'], values['requested_targets'])
            self.assertEqual(values['shortfall_targets'], 0)
        with self.assertRaisesRegex(ValueError, 'train/technical'):
            self.shortfall_selection('train-short', allow=True, train_short=True)

    def test_empty_heldout_split_still_rejected(self):
        with self.assertRaisesRegex(ValueError, 'No unused test documents'):
            self.shortfall_selection('empty-test', allow=True, empty_test=True)

    def test_prepare_publishes_measured_heldout_shortfalls_with_frozen_tokenizer(self):
        mixture = read_json(self.mixture)
        for name in ('kubernetes', 'tensorflow', 'mdn'):
            path = self.raw / name
            source = read_json(path / 'manifest.json')['source']
            lines = (path / 'text.txt').read_text().splitlines(keepends=True)
            rows = []
            for row in read_jsonl(path / 'documents.jsonl'):
                if assigned_split(42, name, row['origin'], mixture) == 'train':
                    start = row['first_line']-1
                    rows.append((row, ''.join(lines[start:start+row['lines']])))
            save_snapshot(self.raw, name, source, rows)
        with contextlib.redirect_stdout(io.StringIO()):
            manifest = prepare(self.config, self.mixture, self.raw, self.notices, self.parent,
                               self.root / 'short-heldout', train_tokens=50, allow_heldout_shortfall=True)
        output = self.root / 'short-heldout'
        report = read_json(output / 'sampling-report.json')
        self.assertTrue(report['allow_heldout_shortfall'])
        self.assertTrue(manifest['corpus_sampling']['allow_heldout_shortfall'])
        for split in ('validation', 'test'):
            self.assertEqual(report['selection'][split]['technical']['actual_targets'], 0)
            self.assertGreater(report['selection'][split]['technical']['shortfall_targets'], 0)
            self.assertEqual(report['actual'][split]['shares']['technical'], 0)
        self.assertGreaterEqual(manifest['splits']['train']['targets'], 50)
        self.assertEqual((self.parent / 'tokenizer.json').read_bytes(), (output / 'tokenizer.json').read_bytes())
        load_bundle(output, load_config(self.config), ('train', 'validation', 'test'))

    def test_prior_paragraph_and_modified_prior_group_are_excluded(self):
        connection = sqlite3.connect(':memory:')
        self.addCleanup(connection.close)
        create_index(connection)
        prior = 'This synthetic paragraph is long enough to test exact prior overlap.'
        connection.execute('INSERT INTO prior_paragraphs VALUES (?)', (fingerprint(normalized(prior)),))
        connection.execute('INSERT INTO prior_groups VALUES (?,?)', ('wikipedia', 'prior-group'))
        for split in ('train', 'validation', 'test'):
            for category, source in [('dialogue', 'lccc'), ('wikipedia', 'wikipedia'), ('technical', 'mdn')]:
                for priority, kind, text in [
                    ('0', 'prior-paragraph', prior + '\nnew suffix ' + split + ' ' + category),
                    ('1', 'usable', 'Fresh ' + split + ' ' + category + ' 𠀀'),
                ]:
                    group = split + '/' + category + '/' + kind
                    connection.execute('INSERT INTO docs VALUES (?,?,?,?,?,?,?,?,?)',
                        (fingerprint(normalized(text)), source, group, split, category, priority, group, text, None))
        text = 'Changed old group text must still be excluded.'
        connection.execute('INSERT INTO docs VALUES (?,?,?,?,?,?,?,?,?)',
            (fingerprint(normalized(text)), 'wikipedia', 'prior-group', 'train', 'wikipedia', '-1', 'fixture', text, None))
        mixture = read_json(self.mixture)
        mixture['train_target_tokens'] = 10
        tokenizer = Tokenizer(300, [])
        counts = Counter()
        audit = self.root / 'selection'
        audit.mkdir()
        with contextlib.redirect_stdout(io.StringIO()):
            select_unused(connection, load_config(self.config), mixture, tokenizer, audit, counts)
        self.assertEqual(counts['excluded_prior_documents_or_groups'], 1)
        self.assertEqual(sum(counts[f'{s}_excluded_prior_paragraph_groups'] for s in ('train', 'validation', 'test')), 9)
        self.assertEqual(connection.execute('SELECT count(*) FROM selected').fetchone()[0], 9)


if __name__ == '__main__':
    unittest.main()
