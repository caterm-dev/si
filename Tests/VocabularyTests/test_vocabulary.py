import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("vocabulary", Path(__file__).resolve().parents[2] / "scripts/vocabulary.py")
vocabulary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vocabulary)


class VocabularyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.save("license.txt", b"Fixture license\n")
        self.sources = [self.source("base", 10, "Apple\nsubtitle\n"),
                        self.source("terms", 20, "apple\nSwiftUI\n")]
        self.configure()
        self.save(vocabulary.DATA / "sources.lock.json", {"schema_version": 1, "sources": {}})
        self.rules([])

    def save(self, path, value):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else vocabulary.json_bytes(value))

    def source(self, name, priority, words):
        self.save(name + ".txt", words.encode())
        return {"id": name, "priority": priority, "path": name + ".txt",
                "license_file": "license.txt", "license_id": "fixture", "origin": "authored fixture",
                "completion_score": 85}

    def configure(self):
        self.save(vocabulary.DATA / "sources.json", {"schema_version": 1, "sources": self.sources})

    def rules(self, rules):
        self.save(vocabulary.DATA / "overrides.json", {"schema_version": 1, "rules": rules})

    def snapshot(self):
        return {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}

    def remote(self):
        source = self.sources[0]
        source["upstream"] = {"repository": "example/words", "ref": "main", "format": "wordlist",
                              "path": "words.txt", "license_path": "LICENSE", "minimum_words": 1,
                              "maximum_words": 100, "minimum_length": 2}
        self.configure()
        current = "1" * 40
        self.save(vocabulary.DATA / "sources.lock.json", {"schema_version": 1, "sources": {"base": {
            "revision": current, "upstream": source["upstream"],
            "download_sha256": vocabulary.digest(b"Apple\nsubtitle\n"),
            "snapshot_sha256": vocabulary.digest((self.root / "base.txt").read_bytes()),
            "license_sha256": vocabulary.digest((self.root / "license.txt").read_bytes()),
        }}})
        return source

    def test_merge_is_repeatable_and_priority_controls_casing_without_losing_origins(self):
        outputs, stats = vocabulary.compile_vocabulary(self.root)
        self.assertEqual(stats["merged_words"], 3)
        self.assertIn(b"apple\tbase,terms\t85\n", outputs[vocabulary.MERGED])
        self.assertEqual(outputs, vocabulary.compile_vocabulary(self.root)[0])
        vocabulary.write_outputs(self.root, outputs)
        vocabulary.write_outputs(self.root, outputs, check=True)
        self.save("terms.txt", b"apple\nSwiftUI\nXcode\n")
        with self.assertRaisesRegex(vocabulary.VocabularyError, "Stale generated"):
            vocabulary.write_outputs(self.root, vocabulary.compile_vocabulary(self.root)[0], check=True)

    def test_legacy_scores_remain_import_metadata_without_generated_swift(self):
        for source in self.sources:
            source["completion_score"] = 75
        self.configure()
        outputs = vocabulary.compile_vocabulary(self.root)[0]
        self.assertTrue(all(path.suffix != ".swift" for path in outputs))
        self.assertIn(b"apple\tbase,terms\t75\n", outputs[vocabulary.MERGED])

    def test_exclusion_and_corrections_survive_new_source_versions(self):
        self.rules([{"word": "subtitle", "action": "exclude", "reason": "Synthetic exclusion"},
                    {"word": "apple", "action": "replace", "replacement": "Apple", "reason": "Canonical case"},
                    {"word": "tyop", "action": "replace", "replacement": "typo", "reason": "Synthetic spelling"}])
        self.save("base.txt", b"Apple\nsubtitle\ntyop\n")
        for additions in [b"", b"world\n"]:
            self.save("base.txt", b"Apple\nsubtitle\ntyop\n" + additions)
            merged = vocabulary.compile_vocabulary(self.root)[0][vocabulary.MERGED]
            self.assertNotIn(b"subtitle\t", merged)
            self.assertNotIn(b"tyop\t", merged)
            self.assertIn(b"Apple\t", merged)
            self.assertIn(b"typo\t", merged)

    def test_invalid_local_words_duplicates_and_rules_fail_before_generation(self):
        baseline = self.snapshot()
        for words in [b"apple\nApple\n", "caf\u00e9\n".encode(), b"two words\n", b"# empty\n"]:
            self.save("terms.txt", words)
            with self.assertRaises((vocabulary.VocabularyError, UnicodeError)):
                vocabulary.compile_vocabulary(self.root)
            self.assertFalse((self.root / vocabulary.MERGED).exists())
        self.save("terms.txt", baseline[Path("terms.txt")])
        self.rules([{"word": "apple", "action": "exclude", "reason": ""}])
        with self.assertRaisesRegex(vocabulary.VocabularyError, "reason"):
            vocabulary.compile_vocabulary(self.root)

    def test_import_filters_unsupported_entries_and_collapses_case_deterministically(self):
        first = b"Apple\napple\nsubtitle\nb\ntwo words\ncan't\ncaf\xc3\xa9\n"
        second = b"apple\nApple\nsubtitle\nb\ntwo words\ncan't\ncaf\xc3\xa9\n"
        snapshot, stats = vocabulary.import_words(first, "wordlist")
        self.assertEqual(snapshot, b"apple\nsubtitle\n")
        self.assertEqual(snapshot, vocabulary.import_words(second, "wordlist")[0])
        self.assertEqual(stats, {"unsupported_rows": 4, "collapsed_case_variants": 1})
        rime = b"---\nname: fixture\n...\nsubtitle\tsubtitle\t100\nSwiftUI\tswiftui\ntext\tshortcut\n"
        self.assertEqual(vocabulary.import_words(rime, "rime")[0], b"subtitle\nSwiftUI\n")
        with self.assertRaises(vocabulary.VocabularyError):
            vocabulary.import_words(b"a\n", "wordlist")

    def test_snapshot_and_license_tampering_are_detected(self):
        self.remote()
        self.save("base.txt", b"changed\n")
        with self.assertRaisesRegex(vocabulary.VocabularyError, "snapshot_sha256"):
            vocabulary.compile_vocabulary(self.root)
        self.save("base.txt", b"Apple\nsubtitle\n")
        self.save("license.txt", b"changed\n")
        with self.assertRaisesRegex(vocabulary.VocabularyError, "license_sha256"):
            vocabulary.compile_vocabulary(self.root)

    def test_cspell_annotations_do_not_rewrite_unsupported_names_or_compounds(self):
        data = b"# Fixture\n  GMail # service\nGitHub\t# tool\nOpenAI\nC#\nC++\n.NET\nfoo#bar\ntwo words\nabc123\n+compound\ntyped\tExpansion\n"
        snapshot, filtering = vocabulary.import_words(data, "cspell")
        self.assertEqual(snapshot, b"GitHub\nGMail\nOpenAI\n")
        self.assertEqual(filtering, {"unsupported_rows": 8, "collapsed_case_variants": 0,
                                     "inline_comments_removed": 2})
        # Existing plain-word-list imports do not reinterpret annotations.
        self.assertEqual(vocabulary.import_words(b"GMail # service\nGitHub\n", "wordlist")[0], b"GitHub\n")

    def test_cspell_refresh_retains_pinned_import_settings_and_casing_overrides(self):
        source = self.remote()
        source["upstream"]["format"] = "cspell"
        self.configure()
        self.rules([{"word": "gmail", "action": "replace", "replacement": "Gmail", "reason": "Preferred case"}])
        data = b"GMail # service\nGitHub\nOpenAI\n"
        download = lambda url: b"Fixture license\n" if url.endswith("LICENSE") else data
        vocabulary.refresh(self.root, "base", revision="2" * 40, download=download)
        merged = (self.root / vocabulary.MERGED).read_text()
        self.assertIn("Gmail\tbase,si-overrides", merged)
        self.assertIn("GitHub\tbase", merged)
        lock = json.loads((self.root / vocabulary.DATA / "sources.lock.json").read_text())
        self.assertEqual(lock["sources"]["base"]["upstream"]["format"], "cspell")
        self.assertEqual(lock["sources"]["base"]["filtering"]["inline_comments_removed"], 1)
        vocabulary.write_outputs(self.root, vocabulary.compile_vocabulary(self.root)[0], check=True)

    def test_refresh_pins_revision_preserves_local_edits_and_applies_exclusions(self):
        self.remote()
        self.rules([{"word": "subtitle", "action": "exclude", "reason": "Keep excluded across updates"}])
        def download(url):
            if "api.github.com" in url:
                return json.dumps({"sha": "2" * 40}).encode()
            if url.endswith("LICENSE"):
                return b"Fixture license\n"
            return b"Apple\nsubtitle\nworld\n"
        stats = vocabulary.refresh(self.root, "base", latest=True, download=download)
        self.assertEqual(stats["merged_words"], 3)
        merged = (self.root / vocabulary.MERGED).read_text()
        self.assertIn("SwiftUI\tterms", merged)
        self.assertIn("world\tbase", merged)
        self.assertNotIn("subtitle\t", merged)
        lock = json.loads((self.root / vocabulary.DATA / "sources.lock.json").read_text())
        self.assertEqual(lock["sources"]["base"]["revision"], "2" * 40)
        vocabulary.write_outputs(self.root, vocabulary.compile_vocabulary(self.root)[0], check=True)

    def test_failed_refresh_leaves_every_file_unchanged(self):
        self.remote()
        before = self.snapshot()
        for words, license_data, revision, message in [
            (b"world\n", b"Changed license\n", "2" * 40, "license changed"),
            (b"123\n", b"Fixture license\n", "2" * 40, "no supported words"),
            (b"world\n", b"Fixture license\n", "1" * 40, "checksum changed"),
        ]:
            with self.assertRaisesRegex(vocabulary.VocabularyError, message):
                vocabulary.refresh(self.root, "base", revision=revision,
                                   download=lambda url: license_data if url.endswith("LICENSE") else words)
            self.assertEqual(before, self.snapshot())
        with self.assertRaises(OSError):
            vocabulary.refresh(self.root, "base", revision="2" * 40,
                               download=lambda url: (_ for _ in ()).throw(OSError("offline")))
        self.assertEqual(before, self.snapshot())

    def test_first_import_requires_review_and_initializes_all_artifacts(self):
        source = self.remote()
        self.save(vocabulary.DATA / "sources.lock.json", {"schema_version": 1, "sources": {}})
        (self.root / "base.txt").unlink()
        source["license_file"] = "new-license.txt"
        self.configure()
        before = self.snapshot()
        download = lambda url: b"Fixture license\n" if url.endswith("LICENSE") else b"subtitle\nworld\n"
        with self.assertRaisesRegex(vocabulary.VocabularyError, "First import"):
            vocabulary.refresh(self.root, "base", revision="2" * 40, download=download)
        self.assertEqual(before, self.snapshot())
        vocabulary.refresh(self.root, "base", revision="2" * 40,
                           accept_license_change=True, download=download)
        vocabulary.write_outputs(self.root, vocabulary.compile_vocabulary(self.root)[0], check=True)

    def test_pinned_refresh_restores_a_damaged_snapshot(self):
        self.remote()
        self.save("base.txt", b"broken\n")
        download = lambda url: b"Fixture license\n" if url.endswith("LICENSE") else b"Apple\nsubtitle\n"
        vocabulary.refresh(self.root, "base", download=download)
        self.assertEqual((self.root / "base.txt").read_bytes(), b"Apple\nsubtitle\n")

    def test_import_size_guard_preserves_existing_files(self):
        source = self.remote()
        source["upstream"]["minimum_words"] = 20
        self.configure()
        before = self.snapshot()
        download = lambda url: b"Fixture license\n" if url.endswith("LICENSE") else b"world\n"
        with self.assertRaisesRegex(vocabulary.VocabularyError, "Unexpected imported size"):
            vocabulary.refresh(self.root, "base", revision="2" * 40, download=download)
        self.assertEqual(before, self.snapshot())

    def test_audit_only_reports_upstream_changes(self):
        self.remote()
        before = self.snapshot()
        report = vocabulary.audit(self.root, download=lambda url: json.dumps({"sha": "2" * 40}).encode())
        self.assertTrue(report["sources"][0]["update_available"])
        self.assertIn("--revision " + "2" * 40, report["sources"][0]["refresh_command"])
        self.assertEqual(before, self.snapshot())

    def test_upstream_audit_falls_back_to_public_git_refs_on_api_rate_limits(self):
        source = self.remote()
        def download(url):
            if "api.github.com" in url:
                raise vocabulary.HTTPError(url, 403, "rate limit", {}, None)
            return ("0000\n" + "2" * 40 + " refs/heads/main\x00capabilities\n").encode()
        self.assertEqual(vocabulary.latest_revision(source, download), "2" * 40)

    def test_scowl_archive_ignores_links_and_rejects_traversal_without_executing(self):
        for name, kind in [("../../outside", tarfile.REGTYPE), ("source/link", tarfile.SYMTYPE)]:
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                archive.addfile(entry)
            with patch.object(vocabulary.subprocess, "run") as run:
                with self.assertRaises(vocabulary.VocabularyError):
                    vocabulary.scowl_export(buffer.getvalue(), 50)
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
