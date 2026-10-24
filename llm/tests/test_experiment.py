import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from experiment import score_case, summarize, validate_training_steps
from prepare import build, export
from protocol import ROOT, Request, compact, finish_candidates, parse_response
from runtime import Generator, NonThinkingTokenizer, model_directory


class ContractTests(unittest.TestCase):
    def test_language_identity_preserves_same_text_and_exact_bytes(self):
        request = Request("e\u0301")
        rows = parse_response(compact({"candidates": [
            {"text": "é", "language": "en"}, {"text": "é", "language": "zh-Hans"},
        ]}), request)
        result = finish_candidates(rows, request)
        self.assertEqual(len(result), 3)
        self.assertEqual(result[-1]["text"].encode(), b"e\xcc\x81")

    def test_canonical_duplicates_are_rejected_within_language(self):
        with self.assertRaises(ValueError):
            parse_response(compact({"candidates": [
                {"text": "é", "language": "en"}, {"text": "e\u0301", "language": "en"},
            ]}), Request("e"))

    def test_disabled_language_and_decorated_json_are_rejected(self):
        for response in ('```json\n{"candidates": []}\n```',
                         '{"candidates":[{"text":"是","language":"zh-Hans"}]}',
                         '{"candidates":[{"text":"hello\\u0000","language":"en"}]}'):
            with self.subTest(response=response), self.assertRaises(ValueError):
                parse_response(response, Request("shi", languages=("en",)))

    def test_empty_and_all_languages_disabled_bypass_model(self):
        self.assertFalse(Request("").needs_model)
        self.assertEqual(finish_candidates([], Request("")), [])
        request = Request("OriginalCASE_7", languages=())
        result = subprocess.run(
            [sys.executable, str(ROOT / "experiment.py"), "infer", "--model", "/missing/model"],
            input=compact(request.as_dict()), text=True, capture_output=True, check=True,
        )
        self.assertEqual(json.loads(result.stdout)["candidates"], [
            {"text": request.input, "language": "verbatim"},
        ])

    def test_prediction_is_a_suffix_task_without_literal_injection(self):
        request = Request("", context="Good", task="predict", languages=("en",))
        self.assertTrue(request.needs_model)
        rows = parse_response('{"candidates":[{"text":" morning","language":"en"}]}', request)
        self.assertEqual(finish_candidates(rows, request), rows)
        self.assertFalse(Request("", task="predict").needs_model)

    def test_invalid_bounds_and_request_fields(self):
        for value in ({"input": "x", "max_candidates": True}, {"input": "x", "languages": ["xx"]},
                      {"input": "x", "task": "chat"}, {"input": "x", "unknown": "x"},
                      {"input": "界" * 1366}):
            with self.subTest(value=list(value)), self.assertRaises(ValueError):
                Request.from_dict(value)

    def test_truncated_generation_discards_list_and_retains_literal(self):
        generator = Generator.__new__(Generator)
        generator.model, generator.sampler, generator.max_tokens = None, None, 10
        generator.tokenizer = types.SimpleNamespace(apply_chat_template=lambda *args, **kwargs: "prompt")
        response = types.SimpleNamespace(
            text='{"candidates":[{"text":"你好","language":"zh-Hans"}]}',
            finish_reason="length", generation_tokens=10,
        )
        fake = types.SimpleNamespace(stream_generate=lambda *args, **kwargs: iter([response]))
        with patch.dict(sys.modules, {"mlx_lm": fake}):
            result = generator.generate(Request("nihao"))
        self.assertEqual(result["status"], "invalid_response")
        self.assertEqual(result["candidates"], [{"text": "nihao", "language": "verbatim"}])

    def test_training_and_inference_disable_thinking(self):
        calls = []
        tokenizer = types.SimpleNamespace(apply_chat_template=lambda *args, **kwargs: calls.append(kwargs))
        NonThinkingTokenizer(tokenizer).apply_chat_template([], enable_thinking=True)
        self.assertFalse(calls[0]["enable_thinking"])

    def test_model_ids_are_never_used_as_download_instructions(self):
        with self.assertRaises(ValueError):
            model_directory("Qwen/not-a-local-snapshot")


class DatasetTests(unittest.TestCase):
    def test_training_cannot_finish_without_applying_accumulated_gradients(self):
        with self.assertRaises(ValueError):
            validate_training_steps({"iters": 2, "grad_accumulation_steps": 4})
        validate_training_steps({"iters": 4, "grad_accumulation_steps": 4})

    def test_reproducible_exports_and_stale_detection(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            first = export(ROOT / "data/seeds.jsonl", target)
            second = export(ROOT / "data/seeds.jsonl", target, check=True)
            self.assertEqual(first, second)
            (target / "train.jsonl").write_text("{}\n")
            with self.assertRaises(ValueError):
                export(ROOT / "data/seeds.jsonl", target, check=True)

    def test_variants_cannot_cross_splits(self):
        seed = json.loads((ROOT / "data/seeds.jsonl").read_text().splitlines()[0])
        other = copy.deepcopy(seed)
        other.update(id="another", split="test")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "seeds.jsonl"
            source.write_text(compact(seed) + "\n" + compact(other) + "\n")
            with self.assertRaisesRegex(ValueError, "group crosses"):
                build(source)

    def test_exported_training_prompt_matches_inference_request(self):
        data = build(ROOT / "data/seeds.jsonl")
        for rows in data.values():
            for row in rows:
                request = Request.from_dict(row["request"])
                self.assertEqual(json.loads(request.messages()[1]["content"]), row["request"])


class EvaluationTests(unittest.TestCase):
    def test_literal_fallback_cannot_inflate_preservation_quality(self):
        request = Request("HTTPServer_v3")
        case = {"request": request.as_dict(), "expected": [{"text": request.input, "language": "en"}], "category": "preserve"}
        result = {"candidates": finish_candidates([], request), "status": "invalid_response",
                  "timing": {"total_ms": 5, "first_token_ms": 1}}
        score = score_case(case, result)
        self.assertEqual(score["top1"], 0)
        self.assertEqual(score["literal_ok"], 1)
        self.assertEqual(summarize([score])["preserve_top1_error_rate"], 1)

    def test_invalid_empty_output_is_not_counted_as_correct_abstention(self):
        case = {"request": Request("qzxv").as_dict(), "expected": [], "category": "literal"}
        result = {"candidates": [], "status": "invalid_response", "timing": {"total_ms": 7, "first_token_ms": 2}}
        self.assertEqual(score_case(case, result)["top1"], 0)

    def test_bypasses_do_not_lower_latency_percentiles(self):
        request = Request("x")
        case = {"request": request.as_dict(), "expected": [], "category": "literal"}
        result = {"candidates": [], "status": "ok", "timing": {"total_ms": 100, "first_token_ms": 25}}
        generated = score_case(case, result)
        bypass = {**generated, "bypassed": 1, "total_ms": 0.01, "first_token_ms": None}
        report = summarize([generated, bypass])
        self.assertEqual(report["generated_requests"], 1)
        self.assertEqual(report["total_ms_p50"], 100)


if __name__ == "__main__":
    unittest.main()
