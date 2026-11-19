import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import torch

from llm.pinyin_to_text.common import CONTEXTUAL_PINYIN, read_json, write_json
from llm.pinyin_to_text.csv_data.prepare import prepare, read_collection
from llm.pinyin_to_text.evaluate import evaluate
from llm.pinyin_to_text.metrics import cases
from llm.pinyin_to_text.runtime import candidates, load_bundle, load_checkpoint
from llm.pinyin_to_text.tests.helpers import ROOT, tiny_config
from llm.pinyin_to_text.tokenizer import BOS, EOS, PAD, PINYIN_START, Tokenizer
from llm.pinyin_to_text.train import train


CSV_ROOT = ROOT / "data/contextual-pinyin-csv"


class ContextualPinyinTests(unittest.TestCase):
    def test_source_keeps_all_syllables_and_fits_whole_unicode_context_suffix(self):
        tokenizer = Tokenizer(512, [])
        model = {"source_format": CONTEXTUAL_PINYIN, "max_source_tokens": 14}
        tokens = tokenizer.encode_source("fangan", model, context="先定个😀", syllables="fang an")
        boundary = tokens.index(PINYIN_START)
        self.assertEqual(len(tokens), 14)
        self.assertEqual(tokenizer.decode([*tokens[:boundary], EOS]), "😀")
        self.assertEqual(tokenizer.decode(tokens[boundary + 1:]), "fang an")
        self.assertNotIn(PINYIN_START, tokenizer.active_ids)
        for wrong in ("fan  gan", "fang ga"):
            with self.subTest(wrong=wrong), self.assertRaisesRegex(ValueError, "match input"):
                tokenizer.encode_source("fangan", model, context="", syllables=wrong)

    def test_multiple_paths_share_one_encoder_and_one_decoder_batch_per_step(self):
        device = torch.device("cpu")
        tokenizer = Tokenizer(512, ["方", "反"])
        expected = {"fang an": tokenizer.lookup["方"], "fan gan": tokenizer.lookup["反"]}
        encoder_batches, decoder_batches = [], []

        class FakeModel:
            config = {"source_format": CONTEXTUAL_PINYIN, "max_source_tokens": 32, "max_target_tokens": 8}

            def encode(self, source):
                encoder_batches.append(source.shape[0])
                return source, source.eq(PAD)

            def decode(self, target, memory, padding):
                decoder_batches.append(target.shape[0])
                logits = torch.full((*target.shape, tokenizer.vocab_size), -100.0)
                for index, row in enumerate(memory.tolist()):
                    self.assert_context(row)
                    pinyin = tokenizer.decode(row[row.index(PINYIN_START) + 1:])
                    token = expected[pinyin] if target[index, -1] == BOS else EOS
                    logits[index, -1, token] = 0
                return logits

            @staticmethod
            def assert_context(row):
                if tokenizer.decode(row[:row.index(PINYIN_START)]) != "先定个":
                    raise AssertionError("Context was lost during batching")

        prediction = candidates(FakeModel(), tokenizer, "fangan", device, 2, .6,
                                context="先定个", syllable_paths=["fang an", "fan gan", "fang an"])
        self.assertEqual(prediction, {"model_candidates": ["方", "反"], "candidates": ["方", "反", "fangan"]})
        self.assertEqual(encoder_batches, [2])
        self.assertEqual(decoder_batches[:2], [2, 4])
        self.assertEqual(candidates(FakeModel(), tokenizer, "fang", device, 2, .6)["candidates"], ["fang"])

    def test_preparation_and_evaluation_keep_context_targets_separate(self):
        splits, *_ = read_collection(CSV_ROOT)
        readings = [case for case in cases(splits["validation"]) if case["input"] == "xian"]
        self.assertEqual({frozenset(case["targets"]) for case in readings}, {frozenset({"先"}), frozenset({"西安"})})
        self.assertTrue(all(case["syllables"] == {"xi an", "xian"} for case in readings))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = tiny_config(root, max_steps=1)
            config = read_json(config_path)
            config["model"]["source_format"] = CONTEXTUAL_PINYIN
            write_json(config_path, config)
            data, run, report = (root / name for name in ("data", "run", "eval.json"))
            prepare(config_path, CSV_ROOT, data)
            manifest, _, _ = load_bundle(data, config, ("train",))
            self.assertEqual(manifest["model_limits"]["source_format"], CONTEXTUAL_PINYIN)
            with contextlib.redirect_stdout(io.StringIO()):
                train(config_path, data, run, "cpu", threads=2)
            checkpoint = run / "best.pt"
            _, model, _ = load_checkpoint(checkpoint, "cpu")
            self.assertEqual(model.config["source_format"], CONTEXTUAL_PINYIN)
            result = evaluate(data, "test", report, checkpoint, device_name="cpu", threads=2)
            self.assertEqual(result["evaluated_cases"], 3)
