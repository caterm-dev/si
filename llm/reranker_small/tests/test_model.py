from collections import Counter
import unittest

import torch
from torch.nn import functional as F

from llm.reranker_small.model import CharacterLM, parameter_report
from llm.reranker_small.runtime import rank_candidates, validation_loss
from llm.reranker_small.settings import ROOT, load_config
from llm.reranker_small.tokenizer import BOS, PAD, fit_counts


class ModelTests(unittest.TestCase):
    def setUp(self):
        torch.set_num_threads(2)
        torch.manual_seed(42)
        self.config = load_config(ROOT / 'configs/smoke.json')['model']
        self.config['dropout'] = 0
        self.tokenizer = fit_counts(Counter('甲乙丙中文测试我们你好'), self.config['vocab_size'])
        self.model = CharacterLM(self.config, self.tokenizer.active_ids).eval()

    def test_real_baseline_parameter_count(self):
        self.assertEqual(parameter_report(load_config(ROOT / 'configs/small.json')['model'])['parameters'], 7419392)

    def test_causality_and_right_padding(self):
        values = torch.tensor([self.tokenizer.encode('甲乙丙')[:-1]])
        changed = values.clone()
        changed[0, -1] = self.tokenizer.encode('中')[1]
        with torch.no_grad():
            original = self.model(values)
            other = self.model(changed)
            padded = self.model(F.pad(values, (0, 3), value=PAD))[:, :values.shape[1]]
        active = self.tokenizer.active_ids
        torch.testing.assert_close(original[:, :-1, active], other[:, :-1, active])
        torch.testing.assert_close(original[:, :, active], padded[:, :, active], atol=1e-5, rtol=1e-5)

    def test_first_candidate_character_is_scored_from_last_prefix_position(self):
        result = rank_candidates(self.model, self.tokenizer, '甲', ['乙', '丙'], torch.device('cpu'))
        prefix = torch.tensor([[BOS, self.tokenizer.encode('甲')[1]]])
        with torch.no_grad():
            log_probs = self.model(prefix)[0, -1].log_softmax(-1)
        for index, text in enumerate(['乙', '丙']):
            self.assertAlmostEqual(result['scores'][index], float(log_probs[self.tokenizer.encode(text)[1]]), places=5)

    def test_lossless_fallback_order_ties_empty_and_long_candidate_abstention(self):
        unknown = '𠮷🧪e\u0301'
        self.assertEqual(self.tokenizer.decode(self.tokenizer.encode(unknown)), unknown)
        result = rank_candidates(self.model, self.tokenizer, '甲' * 100, [unknown, unknown], torch.device('cpu'))
        self.assertEqual(result['order'], [0, 1])
        self.assertEqual(result['scores'][0], result['scores'][1])
        self.assertEqual(rank_candidates(self.model, self.tokenizer, '', [], torch.device('cpu'))['order'], [])
        result = rank_candidates(self.model, self.tokenizer, '', ['甲' * 33, '乙'], torch.device('cpu'))
        self.assertTrue(result['abstained'])
        self.assertEqual(result['order'], [0, 1])
        result = rank_candidates(self.model, self.tokenizer, '甲🧪', ['甲' * 30], torch.device('cpu'))
        self.assertEqual(result['context_tokens_used'], 0)  # Four-byte scalar cannot fit a two-token suffix budget.

    def test_small_model_actually_learns_a_candidate_preference(self):
        optimizer = torch.optim.AdamW(self.model.parameters(), lr=0.01)
        values = torch.tensor([[BOS, self.tokenizer.encode('甲')[1]]])
        labels = torch.tensor([[self.tokenizer.encode('甲')[1], self.tokenizer.encode('乙')[1]]])
        losses = []
        self.model.train()
        for _ in range(35):
            optimizer.zero_grad(set_to_none=True)
            loss = F.cross_entropy(self.model(values).flatten(0, 1), labels.flatten())
            loss.backward()
            optimizer.step()
            losses.append(float(loss.detach()))
        self.assertLess(losses[-1], losses[0] * 0.2)
        result = rank_candidates(self.model, self.tokenizer, '甲', ['丙', '乙'], torch.device('cpu'))
        self.assertEqual(result['order'][0], 1)

    def test_partial_validation_samples_sources_without_advancing_training_rng(self):
        token = self.tokenizer.encode('甲')[1]
        class Dataset:
            seen = []
            def __len__(self):
                return 10
            def batch(self, indices, device):
                self.seen.extend(indices)
                return (torch.full((len(indices), 1), BOS, device=device),
                        torch.full((len(indices), 1), token, device=device))
        dataset = Dataset()
        before = torch.get_rng_state()
        result = validation_loss(self.model, dataset, 2, torch.device('cpu'), max_tokens=4)
        self.assertEqual(result['tokens'], 4)
        self.assertEqual({index // 5 for index in dataset.seen}, {0, 1})
        self.assertTrue(torch.equal(before, torch.get_rng_state()))

    @unittest.skipUnless(torch.backends.mps.is_available(), 'MPS unavailable')
    def test_mps_matches_cpu_and_full_baseline_backward_is_finite(self):
        mps = CharacterLM(self.config, self.tokenizer.active_ids).to('mps').eval()
        mps.load_state_dict(self.model.state_dict())
        tokens = torch.tensor([self.tokenizer.encode('中文测试')[:-1]])
        with torch.no_grad():
            expected = self.model(tokens)[:, :, self.tokenizer.active_ids]
            actual = mps(tokens.to('mps'))[:, :, self.tokenizer.active_ids].cpu()
        torch.testing.assert_close(actual, expected, atol=1e-4, rtol=1e-4)
        config = load_config(ROOT / 'configs/small.json')['model']
        model = CharacterLM(config).to('mps').train()
        values = torch.randint(4, 260, (2, 257), device='mps')
        loss = F.cross_entropy(model(values[:, :-1]).flatten(0, 1), values[:, 1:].reshape(-1))
        loss.backward()
        self.assertTrue(torch.isfinite(loss))
        self.assertTrue(all(p.grad is not None and torch.isfinite(p.grad).all() for p in model.parameters()))
