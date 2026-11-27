"""Small synthetic checks for new-data weight initialization and exact continuation."""

import contextlib
import io
import math
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import torch

from llm.reranker_large.corpus_data import prepare_corpus
from llm.reranker_large.export import export
from llm.reranker_large.scripts import continue_pretrain as continuation
from llm.reranker_large.scripts.prepare_extra_data import prepare
from llm.reranker_large.settings import code_identity, file_hash, fingerprint, read_json, write_json
from llm.reranker_large.tests.test_corpus import fixture
from llm.reranker_large.train import train as train_parent


class ContinuationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='si-continuation-test-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.config, mixture, raw, notices = fixture(self.root/'input')
        value = read_json(self.config)
        value['training'].update(batch_size=1, gradient_accumulation=2, max_steps=100,
                                 schedule_steps=100, validate_every=1, save_every=1, warmup_steps=1)
        write_json(self.config, value)
        self.parent_data, self.data = self.root/'parent-data', self.root/'new-data'
        self.parent_run = self.root/'parent-run'
        with contextlib.redirect_stdout(io.StringIO()):
            prepare_corpus(self.config, mixture, raw, notices, self.parent_data)
            train_parent(self.config, self.parent_data, self.parent_run, 'cpu', max_steps=1, threads=1)
            prepare(self.config, mixture, raw, notices, self.parent_data, self.data, train_tokens=50)
        self.parent = self.parent_run/'last.pt'
        self.parent_hash = file_hash(self.parent)
        value['training']['single_pass'] = True
        self.config = self.root/'continuation.json'
        write_json(self.config, value)

    def run_train(self, name, **kwargs):
        resume = kwargs.get('resume', False)
        with contextlib.redirect_stdout(io.StringIO()):
            return continuation.train(self.config, self.data, self.root/name,
                None if resume else self.parent, device_name='cpu', threads=1, **kwargs)

    def test_check_only_is_read_only_and_old_trainer_identity_unchanged(self):
        identity = code_identity()
        result = self.run_train('check', check_only=True)
        windows = read_json(self.data/'manifest.json')['splits']['train']['windows']
        self.assertEqual(result['one_pass_steps'], math.ceil(windows/2))
        self.assertFalse(result['training_started'])
        self.assertFalse((self.root/'check').exists())
        self.assertEqual(result['initial_checkpoint']['step'], 1)
        self.assertEqual(file_hash(self.parent), self.parent_hash)
        self.assertEqual(code_identity(), identity)

    def test_initial_weights_are_identical_but_optimizer_and_counters_are_fresh(self):
        parent = torch.load(self.parent, weights_only=True)
        self.assertTrue(parent['optimizer']['state'])
        saved = []
        actual_save = continuation.atomic_checkpoint

        def capture(path, value):
            if not saved:
                self.assertEqual(value['step'], 0)
                self.assertEqual(value['tokens_seen'], 0)
                self.assertFalse(value['optimizer']['state'])
                for key, tensor in parent['model'].items():
                    self.assertTrue(torch.equal(tensor, value['model'][key]))
            saved.append(path.name)
            actual_save(path, value)

        with mock.patch.object(continuation, 'atomic_checkpoint', side_effect=capture):
            self.run_train('fresh', max_steps=1)
        checkpoint = torch.load(self.root/'fresh/last.pt', weights_only=True)
        self.assertEqual(checkpoint['initial_checkpoint']['sha256'], self.parent_hash)
        self.assertEqual(checkpoint['step'], 1)
        self.assertEqual(checkpoint['dataset_id'], read_json(self.data/'manifest.json')['dataset_id'])
        self.assertEqual(file_hash(self.parent), self.parent_hash)

    def test_single_pass_resume_is_bitwise_and_exports_with_lineage(self):
        target = self.data/'test.tokens.bin'
        hidden = target.with_suffix('.hidden')
        target.rename(hidden)
        try:
            self.run_train('resumed', max_steps=1)
            self.run_train('resumed', resume=True, max_steps=100)
            result = self.run_train('whole')
        finally:
            hidden.rename(target)
        full = torch.load(self.root/'whole/last.pt', weights_only=True)
        resumed = torch.load(self.root/'resumed/last.pt', weights_only=True)
        manifest = read_json(self.data/'manifest.json')
        self.assertTrue(result['pass_complete'])
        self.assertEqual(result['tokens_seen'], manifest['splits']['train']['targets'])
        self.assertEqual(full['cursor'], manifest['splits']['train']['windows'])
        self.assertEqual(full['epoch'], 0)
        for key, tensor in full['model'].items():
            self.assertTrue(torch.equal(tensor, resumed['model'][key]), key)
        self.assertEqual(full['lineage_dataset_ids'], sorted([manifest['dataset_id'], manifest['parent_dataset_id']]))
        exported = export(self.root/'whole/best.pt', self.data, self.root/'export')
        self.assertEqual(exported['initial_checkpoint']['sha256'], self.parent_hash)
        self.assertEqual(exported['stage'], 'pretrain')
        with self.assertRaisesRegex(ValueError, 'budget'):
            self.run_train('whole', resume=True, max_steps=1000)

    def test_ancestor_exclusion_and_tokenizer_mismatches_are_rejected_atomically(self):
        manifest = read_json(self.data/'manifest.json')
        original = (self.data/'manifest.json').read_bytes()
        manifest['excluded_dataset_ids'] = []
        manifest.pop('dataset_id')
        manifest['dataset_id'] = fingerprint(manifest)
        write_json(self.data/'manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'exclude every ancestor'):
            self.run_train('bad-lineage')
        self.assertFalse((self.root/'bad-lineage').exists())
        (self.data/'manifest.json').write_bytes(original)
        parent = torch.load(self.parent, weights_only=True)
        parent['tokenizer_digest'] = 'invalid'
        bad = self.root/'bad-parent.pt'
        torch.save(parent, bad)
        with self.assertRaisesRegex(ValueError, 'frozen tokenizer'):
            continuation.train(self.config, self.data, self.root/'bad-tokenizer', bad,
                               device_name='cpu', threads=1)
        self.assertFalse((self.root/'bad-tokenizer').exists())

    def test_existing_run_and_changed_resume_config_are_rejected(self):
        self.run_train('partial', max_steps=1)
        pin = file_hash(self.root/'partial/last.pt')
        with self.assertRaises(FileExistsError):
            self.run_train('partial')
        config = read_json(self.config)
        config['training']['learning_rate'] *= 2
        write_json(self.config, config)
        with self.assertRaisesRegex(ValueError, 'Resume requires'):
            self.run_train('partial', resume=True, max_steps=100)
        self.assertEqual(file_hash(self.root/'partial/last.pt'), pin)

    def test_export_style_ancestor_metadata_cannot_bypass_exclusions(self):
        parent = torch.load(self.parent, weights_only=True)
        parent['initial_checkpoint'] = dict(dataset_id='older-parent', ancestor_dataset_ids=['oldest-parent'])
        parent.pop('lineage_dataset_ids', None)
        path = self.root/'ancestor-parent.pt'
        torch.save(parent, path)
        with self.assertRaisesRegex(ValueError, 'exclude every ancestor'):
            continuation.train(self.config, self.data, self.root/'bad-ancestor', path,
                               device_name='cpu', threads=1)
        self.assertFalse((self.root/'bad-ancestor').exists())


if __name__ == '__main__':
    unittest.main()
