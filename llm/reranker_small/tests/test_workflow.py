import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import torch

from llm.reranker_small.benchmark import benchmark
from llm.reranker_small.evaluate import evaluate
from llm.reranker_small.export import export
from llm.reranker_small.fixtures import fixture
from llm.reranker_small.prepare import prepare
from llm.reranker_small.runtime import load_checkpoint, rank_candidates
from llm.reranker_small.settings import ROOT, file_hash, read_json, write_json
from llm.reranker_small.train import train


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.config, lock, raw = fixture(cls.root / 'fixture')
        config = read_json(cls.config)
        config['training'].update(batch_size=64, gradient_accumulation=2)
        write_json(cls.config, config)
        cls.data = cls.root / 'data'
        prepare(cls.config, cls.data, lock, raw)
        with contextlib.redirect_stdout(io.StringIO()):
            train(cls.config, cls.data, cls.root / 'full', 'cpu', max_steps=4, threads=2)
            train(cls.config, cls.data, cls.root / 'resumed', 'cpu', max_steps=2, threads=2)
            train(cls.config, cls.data, cls.root / 'resumed', 'cpu', resume=True, max_steps=4, threads=2)
        cls.checkpoint = cls.root / 'full/best.pt'

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_resume_matches_continuous_training_with_dropout_and_epoch_changes(self):
        full = torch.load(self.root / 'full/last.pt', weights_only=True)
        resumed = torch.load(self.root / 'resumed/last.pt', weights_only=True)
        self.assertGreater(full['epoch'], 0)
        self.assertEqual((full['epoch'], full['cursor'], full['tokens_seen']),
                         (resumed['epoch'], resumed['cursor'], resumed['tokens_seen']))
        self.assertTrue(torch.equal(full['torch_rng'], resumed['torch_rng']))
        for name, parameter in full['model'].items():
            self.assertTrue(torch.equal(parameter, resumed['model'][name]), name)

    def test_changed_config_and_existing_runs_are_rejected(self):
        before = file_hash(self.root / 'resumed/last.pt')
        settings = read_json(self.config)
        settings['training']['learning_rate'] *= 2
        other = self.root / 'other.json'
        write_json(other, settings)
        with self.assertRaisesRegex(ValueError, 'Resume requires'):
            train(other, self.data, self.root / 'resumed', 'cpu', resume=True, max_steps=5, threads=2)
        with self.assertRaises(FileExistsError):
            train(self.config, self.data, self.root / 'resumed', 'cpu', max_steps=1, threads=2)
        self.assertEqual(before, file_hash(self.root / 'resumed/last.pt'))

    def test_training_does_not_open_test_tokens(self):
        path = self.data / 'test.tokens.bin'
        original = path.read_bytes()
        try:
            path.write_bytes(b'not a token array')
            with contextlib.redirect_stdout(io.StringIO()):
                train(self.config, self.data, self.root / 'without-test', 'cpu', max_steps=1, threads=2)
            with self.assertRaisesRegex(ValueError, 'modified'):
                evaluate(self.checkpoint, self.data, self.root / 'bad-test.json', 'test', 'cpu', threads=2)
        finally:
            path.write_bytes(original)

    def test_export_candidate_benchmark_and_explicit_heldout_reports(self):
        destination = self.root / 'export'
        export(self.checkpoint, self.data, destination)
        payload, model, tokenizer = load_checkpoint(destination / 'model.pt', torch.device('cpu'))
        self.assertNotIn('optimizer', payload)
        self.assertNotIn('torch_rng', payload)
        self.assertTrue((destination / 'licenses/fixture.txt').is_file())
        self.assertEqual({s['id'] for s in read_json(destination / 'manifest.json')['sources']}, {'fixture'})
        result = rank_candidates(model, tokenizer, '今天', ['中文测试', '中文侧试'], torch.device('cpu'))
        self.assertEqual(sorted(result['order']), [0, 1])
        report = benchmark(self.checkpoint, ROOT / 'benchmarks/example.jsonl',
                           ROOT / 'benchmarks/example.provenance.json', self.root / 'ranking.json', 'cpu', 2)
        self.assertAlmostEqual(report['candidate_recall'], 2 / 3)
        self.assertEqual(len(report['cases']), 3)
        validation = evaluate(self.checkpoint, self.data, self.root / 'validation.json',
                              'validation', 'cpu', batch_size=2, max_tokens=13, threads=2)
        self.assertEqual(validation['tokens'], 13)
        self.assertTrue(validation['partial'])
        self.assertFalse((self.root / 'test.json').exists())
        metrics = (self.root / 'full/metrics.jsonl').read_text()
        self.assertNotIn('合成文档', metrics)
        with self.assertRaises(FileExistsError):
            export(self.checkpoint, self.data, destination)

    @unittest.skipUnless(torch.backends.mps.is_available(), 'MPS unavailable')
    def test_mps_resume_preserves_dropout_state(self):
        with contextlib.redirect_stdout(io.StringIO()):
            train(self.config, self.data, self.root / 'mps-full', 'mps', max_steps=4, threads=2)
            train(self.config, self.data, self.root / 'mps-resumed', 'mps', max_steps=2, threads=2)
            train(self.config, self.data, self.root / 'mps-resumed', 'mps', resume=True, max_steps=4, threads=2)
            train(self.config, self.data, self.root / 'mps-repeat', 'mps', max_steps=4, threads=2)
        full = torch.load(self.root / 'mps-full/last.pt', weights_only=True)
        resumed = torch.load(self.root / 'mps-resumed/last.pt', weights_only=True)
        repeated = torch.load(self.root / 'mps-repeat/last.pt', weights_only=True)
        self.assertTrue(torch.equal(full['accelerator_rng'], resumed['accelerator_rng']))
        self.assertTrue(torch.equal(full['torch_rng'], resumed['torch_rng']))
        self.assertEqual((full['cursor'], full['tokens_seen']), (resumed['cursor'], resumed['tokens_seen']))
        for name, parameter in full['model'].items():
            # MPS repeated fresh runs also differ below 1e-6. Keep the CPU
            # bitwise test; compare MPS resume and repeat against that same bound.
            torch.testing.assert_close(parameter, resumed['model'][name], atol=1e-6, rtol=1e-5, msg=name)
            torch.testing.assert_close(parameter, repeated['model'][name], atol=1e-6, rtol=1e-5, msg=name)
