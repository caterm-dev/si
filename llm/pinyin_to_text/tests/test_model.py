import unittest
import copy

import torch
from torch.nn import functional as F

from llm.pinyin_to_text.common import load_config
from llm.pinyin_to_text.metrics import cases, edit_distance, summarize
from llm.pinyin_to_text.model import SpellingTransformer, parameter_report
from llm.pinyin_to_text.runtime import candidates, collate, seed_everything, tensors
from llm.pinyin_to_text.tests.helpers import ROOT
from llm.pinyin_to_text.tokenizer import PAD, Tokenizer


class ModelTests(unittest.TestCase):
    def setUp(self):
        torch.set_num_threads(2)
        seed_everything(42)
        self.config = load_config(ROOT / "configs/smoke.json")["model"]
        self.tokenizer = Tokenizer.fit([{"input": "nihao", "target": "你好"}], 512)

    def test_legacy_large_model_parameter_count_is_preserved(self):
        report = parameter_report(load_config(ROOT / "configs/0.4b-static-csv.json")["model"])
        self.assertEqual(report["parameters"], 403069952)
        self.assertTrue(.38 < report["billions"] < .42)

    def test_small_pinyin_model_parameter_count_and_memory_budget(self):
        report = parameter_report(load_config(ROOT / "configs/small-pinyin.json")["model"])
        self.assertEqual(report["parameters"], 19711488)
        self.assertLess(report["fp32_weight_bytes"], 80_000_000)

    def test_decoder_cannot_see_future_and_weights_are_tied(self):
        model = SpellingTransformer(self.config, self.tokenizer.active_ids).eval()
        self.assertIs(model.embedding.weight, model.output.weight)
        source = torch.tensor([self.tokenizer.encode("nihao")])
        a = torch.tensor([[1, 264, 265]])
        b = torch.tensor([[1, 266, 267]])
        with torch.no_grad():
            first, second = model(source, a), model(source, b)
        self.assertTrue(torch.allclose(first[:, 0, self.tokenizer.active_ids], second[:, 0, self.tokenizer.active_ids], atol=1e-6))

    def assert_checkpoint_dropout_gradients(self, device_name):
        config = {**self.config, "encoder_layers": 2, "decoder_layers": 2, "dropout": .1}
        rows = [{"input": "nihao", "target": "你好"}, {"input": "womenzaijia", "target": "我们在家"}]
        tokenizer = Tokenizer.fit(rows, config["vocab_size"])
        device = torch.device(device_name)
        base = SpellingTransformer(config, tokenizer.active_ids).to(device).train()
        batch = collate(tensors(rows, tokenizer, config), device)
        results = []
        for enabled in (False, True):
            model = copy.deepcopy(base)
            model.activation_checkpointing = enabled
            seed_everything(713)
            logits = model(batch[0], batch[1])
            loss = F.cross_entropy(logits.flatten(0, 1), batch[2].flatten(), ignore_index=PAD)
            cpu_rng = torch.get_rng_state().clone()
            device_rng = torch.mps.get_rng_state().clone() if device_name == "mps" else None
            repeated_gradients = []
            for retain_graph in (True, False):
                model.zero_grad(set_to_none=True)
                loss.backward(retain_graph=retain_graph)
                repeated_gradients.append({name: parameter.grad.detach().cpu().clone()
                                           for name, parameter in model.named_parameters()})
                self.assertTrue(torch.equal(cpu_rng, torch.get_rng_state()))
                if device_rng is not None:
                    self.assertTrue(torch.equal(device_rng, torch.mps.get_rng_state()))
            results.append((logits.detach().cpu(), repeated_gradients))
        self.assertTrue(torch.equal(results[0][0], results[1][0]))
        for ordinary, checkpointed in zip(results[0][1], results[1][1]):
            for name in ordinary:
                with self.subTest(device=device_name, parameter=name):
                    self.assertTrue(torch.allclose(ordinary[name], checkpointed[name], atol=1e-6, rtol=1e-5))

    def test_cpu_checkpoint_preserves_dropout_gradients_and_rng(self):
        self.assert_checkpoint_dropout_gradients("cpu")

    @unittest.skipUnless(torch.backends.mps.is_available(), "MPS hardware is unavailable")
    def test_mps_checkpoint_preserves_dropout_gradients_and_rng(self):
        self.assert_checkpoint_dropout_gradients("mps")

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
