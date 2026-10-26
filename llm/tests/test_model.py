import unittest
import copy

import torch
from torch.nn import functional as F

from llm.common import load_config
from llm.metrics import cases, edit_distance, summarize
from llm.model import SpellingTransformer, parameter_report
from llm.runtime import candidates, collate, seed_everything, tensors
from llm.tests.helpers import ROOT
from llm.tokenizer import PAD, Tokenizer


class ModelTests(unittest.TestCase):
    def setUp(self):
        torch.set_num_threads(2)
        seed_everything(42)
        self.config = load_config(ROOT / "configs/smoke.json")["model"]
        self.tokenizer = Tokenizer.fit([{"input": "nihao", "target": "你好"}], 512)

    def test_production_model_really_has_point_four_billion_parameters(self):
        report = parameter_report(load_config(ROOT / "configs/0.4b-static-csv.json")["model"])
        self.assertEqual(report["parameters"], 403069952)
        self.assertTrue(.38 < report["billions"] < .42)

    def test_decoder_cannot_see_future_and_weights_are_tied(self):
        model = SpellingTransformer(self.config, self.tokenizer.active_ids).eval()
        self.assertIs(model.embedding.weight, model.output.weight)
        source = torch.tensor([self.tokenizer.encode("nihao")])
        a = torch.tensor([[1, 264, 265]])
        b = torch.tensor([[1, 266, 267]])
        with torch.no_grad():
            first, second = model(source, a), model(source, b)
        self.assertTrue(torch.allclose(first[:, 0, self.tokenizer.active_ids], second[:, 0, self.tokenizer.active_ids], atol=1e-6))

    def test_tiny_model_can_learn_a_conversion_and_generate_eos(self):
        rows = [{"input": "nihao", "target": "你好"}]
        model = SpellingTransformer(self.config, self.tokenizer.active_ids)
        source, decoder, labels = collate(tensors(rows, self.tokenizer, self.config), torch.device("cpu"))
        optimizer = torch.optim.AdamW(model.parameters(), lr=.01)
        losses = []
        for _ in range(80):
            optimizer.zero_grad()
            logits = model(source, decoder)
            loss = F.cross_entropy(logits.flatten(0, 1), labels.flatten(), ignore_index=PAD)
            losses.append(float(loss.detach()))
            loss.backward()
            optimizer.step()
        self.assertLess(losses[-1], losses[0] / 10)
        model.eval()
        prediction = candidates(model, self.tokenizer, "nihao", torch.device("cpu"), 2, .6)
        self.assertEqual(prediction["model_candidates"][0], "你好")
        self.assertIn("nihao", prediction["candidates"])

    def test_empty_and_oversized_inputs_preserve_contract(self):
        model = SpellingTransformer(self.config, self.tokenizer.active_ids).eval()
        self.assertEqual(candidates(model, self.tokenizer, "", torch.device("cpu"), 2, .6)["candidates"], [])
        text = "A" * 200
        self.assertEqual(candidates(model, self.tokenizer, text, torch.device("cpu"), 2, .6)["candidates"], [text])

    @unittest.skipUnless(torch.backends.mps.is_available(), "MPS hardware is unavailable")
    def test_mps_variable_cross_attention_matches_cpu_with_padding(self):
        cpu = SpellingTransformer(self.config, self.tokenizer.active_ids).eval()
        mps = copy.deepcopy(cpu).to("mps").eval()
        # The 25-source/24-target shape reproduced an MPS hard abort after the
        # shorter shapes in the initial corpus validation pass.
        for source_length, target_length in ((24, 9), (22, 9), (28, 10), (31, 9), (31, 10), (25, 24)):
            source = torch.randint(4, 120, (2, source_length))
            target = torch.randint(4, 120, (2, target_length))
            source[1, -3:] = PAD
            target[1, -2:] = PAD
            with torch.inference_mode():
                expected = cpu(source, target)[:, :, self.tokenizer.active_ids]
                actual = mps(source.to("mps"), target.to("mps")).cpu()[:, :, self.tokenizer.active_ids]
            self.assertTrue(torch.isfinite(actual).all())
            self.assertTrue(torch.allclose(actual, expected, atol=1e-4, rtol=1e-4))

    def test_metrics_separate_literal_recall_and_multiple_references(self):
        rows = [{"input": "women", "target": "我们", "language": "zh", "noise": "clean"},
                {"input": "women", "target": "women", "language": "en", "noise": "clean"},
                {"input": "hello", "target": "hello", "language": "en", "noise": "clean"}]
        grouped = cases(rows)
        metrics = summarize([(grouped[0], {"model_candidates": ["我们"], "candidates": ["我们", "women"]}),
                             (grouped[1], {"model_candidates": [], "candidates": ["hello"]})], 2)
        self.assertEqual(metrics["overall"]["top1_accuracy"], .5)
        self.assertEqual(metrics["overall"]["candidate_recall_with_literal"], 1)
        self.assertEqual(metrics["overall"]["clean_copy_cases"], 1)
        self.assertEqual(metrics["overall"]["clean_copy_error_rate"], 1)
        self.assertEqual(edit_distance("你好", "你们好"), 1)
