import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import chinese_vocabulary as chinese
common = chinese.common


class ChineseVocabularyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.save("LICENSE", b"Fixture GPL notice\n")
        self.sources = [self.source("base", 10, "字\tzi\t100\n行\thang\t98\n行\txing\t99\n"),
                        self.source("si-original", 20, "字\tzi\t101\n")]
        self.configure()
        self.save(chinese.DATA / "sources.lock.json", {"schema_version": 1, "sources": {}})
        self.rules([])

    def save(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else common.json_bytes(value))

    def source(self, sid, priority, text):
        self.save(sid + ".tsv", text.encode())
        return {"id": sid, "priority": priority, "path": sid + ".tsv", "license_file": "LICENSE",
                "license_id": "fixture", "origin": "authored fixture", "weight_kind": "score"}

    def configure(self):
        self.save(chinese.DATA / "sources.json", {"schema_version": 1, "sources": self.sources})

    def rules(self, rules):
        self.save(chinese.DATA / "overrides.json", {"schema_version": 1, "rules": rules})

    def snapshot(self):
        return {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}

    def test_merge_preserves_polyphony_and_source_precedence(self):
        outputs, summary = chinese.compile_vocabulary(self.root)
        self.assertEqual(summary["merged_entries"], 3)
        self.assertEqual(summary["distinct_texts"], 2)
        self.assertIn("字\tzi\t101\tbase,si-original\n".encode(), outputs[chinese.MERGED])
        self.assertIn("行\thang\t98".encode(), outputs[chinese.MERGED])
        self.assertIn("行\txing\t99".encode(), outputs[chinese.MERGED])
        self.assertEqual(outputs, chinese.compile_vocabulary(self.root)[0])
        common.write_outputs(self.root, outputs)
        common.write_outputs(self.root, outputs, check=True)

    def test_import_normalizes_explicit_umlaut_without_changing_text(self):
        raw = "# Source notice\n---\nname: test\n...\n绿\tlü\t100\n绿\tlu:\t200\n绿\tlv\t50\n行\thang\t300\n行\txing\t400\n".encode()
        snapshot, header, counts = chinese.import_rime(raw)
        self.assertEqual(chinese.parse_snapshot(snapshot, "fixture"), {("绿", "lv"): 200, ("行", "hang"): 300, ("行", "xing"): 400})
        self.assertIn(b"Source notice", header)
        self.assertEqual(counts["duplicates"], 2)

    def test_import_filtering_is_explicit_and_missing_pronunciations_are_rejected(self):
        raw = "---\nname: fixture\n...\n字幕\tzi mu\t20000\n词库\tci ku\t100\nT恤\tti xu\t30000\n错误\tcuo\t30000\n".encode()
        snapshot, _, counts = chinese.import_rime(raw, 10000)
        self.assertEqual(snapshot, "字幕\tzi mu\t20000\n".encode())
        self.assertEqual(counts["below_minimum_weight"], 1)
        self.assertEqual(counts["unsupported_text_or_reading"], 2)
        for data in [b"---\ncolumns:\n  - text\n  - weight\n...\n", "---\n...\n字幕\t100\n".encode(), "---\n...\n字幕\tzi mu\tNaN\n".encode()]:
            with self.assertRaises(common.VocabularyError):
                chinese.import_rime(data)

    def test_exclusions_and_reading_corrections_survive_upstream_changes(self):
        self.rules([{"text": "行", "reading": "hang", "action": "exclude", "reason": "Synthetic exclusion"},
                    {"text": "字", "reading": "zi", "action": "replace",
                     "replacement": {"text": "字", "reading": "zi", "score": 105}, "reason": "Editorial preference"}])
        for weight in [98, 100]:
            self.save("base.tsv", f"字\tzi\t100\n行\thang\t{weight}\n行\txing\t99\n".encode())
            merged = chinese.compile_vocabulary(self.root)[0][chinese.MERGED]
            self.assertNotIn("行\thang\t".encode(), merged)
            self.assertIn("行\txing\t".encode(), merged)
            self.assertIn("字\tzi\t105\tbase,si-original,si-overrides".encode(), merged)

    def test_invalid_local_entries_and_overrides_do_not_generate_outputs(self):
        for data in ["字\tzi\t100\n字\tZI\t99\n", "字幕\tzi\t100\n", "字\tzi\t-1\n"]:
            self.save("base.tsv", data.encode())
            with self.assertRaises(common.VocabularyError):
                chinese.compile_vocabulary(self.root)
            self.assertFalse((self.root / chinese.GENERATED).exists())

    def test_frequency_mapping_is_bounded_monotonic_and_not_raw_frequency_scores(self):
        source = {"weight_kind": "frequency", "score_min": 92, "score_max": 99}
        values = [chinese.score_for(weight, source) for weight in [0, 1, 9, 10, 10000, 100000, 10**14]]
        self.assertEqual(values, sorted(values))
        self.assertEqual(values[-1], 99)
        self.assertEqual(chinese.score_for(10000, source), 96)

    def remote(self):
        source = self.sources[0]
        raw = "# Attribution\n---\nname: test\n...\n字\tzi\t100\n行\thang\t98\n行\txing\t99\n".encode()
        snapshot, header, filtering = chinese.import_rime(raw)
        self.save(source["path"], snapshot)
        source["group"] = "rime-ice"
        source["attribution_file"] = "attribution.txt"
        source["upstream"] = {"repository": "example/ice", "ref": "main", "format": "rime-pinyin",
                              "path": "dictionary.yaml", "license_path": "LICENSE", "minimum_words": 1,
                              "maximum_words": 100, "minimum_length": 1, "minimum_weight": 0}
        self.save("attribution.txt", header)
        self.configure()
        self.save(chinese.DATA / "sources.lock.json", {"schema_version": 1, "sources": {"base": {
            "revision": "1" * 40, "upstream": source["upstream"], "download_sha256": common.digest(raw),
            "snapshot_sha256": common.digest(snapshot), "license_sha256": common.digest(b"Fixture GPL notice\n"),
            "attribution_sha256": common.digest(header), "filtering": filtering}}})
        return source, raw

    def test_refresh_keeps_local_overrides_and_pins_pronunciations_and_notices(self):
        self.remote()
        self.rules([{"text": "行", "reading": "hang", "action": "exclude", "reason": "Synthetic"}])
        raw = "# New attribution\n---\n...\n字\tzi\t100\n行\thang\t98\n行\txing\t99\n字幕\tzi mu\t99\n".encode()
        def download(url):
            if "api.github.com" in url:
                return common.json_bytes({"sha": "2" * 40})
            return b"Fixture GPL notice\n" if url.endswith("LICENSE") else raw
        summary = chinese.refresh(self.root, "rime-ice", latest=True, download=download)
        self.assertEqual(summary["merged_entries"], 3)
        result = (self.root / chinese.MERGED).read_text()
        self.assertNotIn("行\thang\t", result)
        self.assertIn("字\tzi\t101", result)
        lock = json.loads((self.root / chinese.DATA / "sources.lock.json").read_text())
        self.assertEqual(lock["sources"]["base"]["revision"], "2" * 40)
        self.assertIn(b"New attribution", (self.root / "attribution.txt").read_bytes())
        common.write_outputs(self.root, chinese.compile_vocabulary(self.root)[0], check=True)

    def test_failed_refresh_preserves_all_sources_and_generated_files(self):
        self.remote()
        before = self.snapshot()
        for raw, license_data, revision in [("---\n...\n字幕\t100\n".encode(), b"Fixture GPL notice\n", "2" * 40),
                                          ("---\n...\n字幕\tzi mu\t100\n".encode(), b"Changed license\n", "2" * 40),
                                          ("---\n...\n字幕\tzi mu\t100\n".encode(), b"Fixture GPL notice\n", "1" * 40)]:
            with self.assertRaises(common.VocabularyError):
                chinese.refresh(self.root, "base", revision=revision,
                                download=lambda url: license_data if url.endswith("LICENSE") else raw)
            self.assertEqual(before, self.snapshot())

    def test_a_failed_second_table_leaves_the_entire_group_unchanged(self):
        source, raw = self.remote()
        second = copy.deepcopy(source)
        second.update(id="second", priority=15, path="second.tsv", attribution_file="second-attribution.txt")
        second["upstream"]["path"] = "second.yaml"
        self.sources.append(second)
        self.configure()
        self.save("second.tsv", (self.root / source["path"]).read_bytes())
        self.save("second-attribution.txt", (self.root / source["attribution_file"]).read_bytes())
        lock_path = chinese.DATA / "sources.lock.json"
        lock = json.loads((self.root / lock_path).read_text())
        lock["sources"]["second"] = dict(lock["sources"]["base"], upstream=second["upstream"])
        self.save(lock_path, lock)
        before = self.snapshot()
        def download(url):
            if url.endswith("LICENSE"):
                return b"Fixture GPL notice\n"
            return b"malformed" if url.endswith("second.yaml") else raw
        with self.assertRaises(common.VocabularyError):
            chinese.refresh(self.root, "rime-ice", revision="2" * 40, download=download)
        self.assertEqual(before, self.snapshot())

    def test_attribution_tampering_and_import_settings_changes_are_detected(self):
        source, _ = self.remote()
        self.save("attribution.txt", b"tampered\n")
        with self.assertRaisesRegex(common.VocabularyError, "attribution_sha256"):
            chinese.compile_vocabulary(self.root)
        source["upstream"]["minimum_weight"] = 100
        self.configure()
        with self.assertRaisesRegex(common.VocabularyError, "import settings changed"):
            chinese.compile_vocabulary(self.root)

    def test_audit_uses_chinese_refresh_commands_without_writing_data(self):
        self.remote()
        before = self.snapshot()
        report = common.audit(self.root, download=lambda url: common.json_bytes({"sha": "2" * 40}), data_dir=chinese.DATA, language="chinese")
        self.assertIn("--language chinese refresh base", report["sources"][0]["refresh_command"])
        self.assertEqual(before, self.snapshot())


if __name__ == "__main__":
    unittest.main()
