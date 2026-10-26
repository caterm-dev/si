import tempfile
import unittest

from llm.common import load_config, read_json, write_json
from llm.tests.helpers import tiny_config
from llm.tokenizer import Tokenizer


class TokenizerTests(unittest.TestCase):
    def test_lossless_unknown_unicode_and_exact_case(self):
        tokenizer = Tokenizer.fit([{"input": "nihao", "target": "你好"}], 264)
        for text in ("你好", "HelloWorld42", "女lüu:", "\U00020000🙂e\u0301", "", "a'b"):
            self.assertEqual(tokenizer.decode(tokenizer.encode(text)), text)

    def test_vocabulary_fits_only_training_characters(self):
        tokenizer = Tokenizer.fit([{"input": "wo", "target": "我"}], 512)
        self.assertNotIn("家", tokenizer.lookup)
        self.assertEqual(tokenizer.decode(tokenizer.encode("家")), "家")

    def test_invalid_utf8_is_rejected(self):
        with self.assertRaises(UnicodeDecodeError):
            Tokenizer(512, []).decode([4 + 0xFF])

    def test_non_csv_data_configuration_fails_early(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = tiny_config(temporary)
            config = read_json(path)
            config["data"] = {"format": "random-generated"}
            write_json(path, config)
            with self.assertRaisesRegex(ValueError, "static-csv"):
                load_config(path)
