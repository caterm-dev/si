"""Public synthetic fixtures for the shared English/Chinese database contract."""
import contextlib
import gzip
import io
import json
import math
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import english_dictionary as dictionary
import lexicon_database as lexicon


class EnglishDictionaryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.data = self.root / "source"
        self.output = self.root / "output"
        self.data.mkdir()
        edits = patch.multiple(dictionary, ROOT=self.root, DATA=self.data, RESOURCES=self.output)
        edits.start()
        self.addCleanup(edits.stop)
        raw = b"Apple\tapple\t20\nappletree\tappletree\t5\nalpha\talpha\t5\nApple\tapple\t10\n"
        (self.data / "base.gz").write_bytes(gzip.compress(raw, mtime=0))
        (self.root / "NOTICE").write_bytes(b"Synthetic notice")
        (self.data / "sources.lock.json").write_text(json.dumps(dict(
            schema_version=1, dictionary_format=lexicon.FORMAT, unknown_weight=1,
            notices={"NOTICE": dictionary.digest(b"Synthetic notice")},
            sources=[dict(path="base.gz", size=len(raw), sha256=dictionary.digest(raw))])))
        self.overlay([])

    def overlay(self, entries):
        (self.data / "si-entries.json").write_text(json.dumps(entries))

    def build(self, check=False):
        with contextlib.redirect_stdout(io.StringIO()):
            dictionary.build(check)

    def files(self):
        return {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.output.iterdir()}

    def test_shared_schema_weights_overlay_and_repeatable_check(self):
        self.overlay([dict(text="appletree", reading="appletree", exclude=True, reason="Synthetic exclusion"),
                      dict(text="apricot", reading="apricot", weight=5, reason="Synthetic addition"),
                      dict(text="Apple", reading="apple", weight=40, reason="Synthetic weight correction")])
        self.build()
        with sqlite3.connect(self.output / "si-english.sqlite") as connection:
            rows = connection.execute("SELECT key,value,weight FROM tbl_1_a ORDER BY weight DESC,rowid").fetchall()
            self.assertEqual(rows, [("apple", "Apple", 40), ("alpha", "alpha", 5), ("apricot", "apricot", 5)])
            self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone(), ("ok",))
            self.assertEqual(connection.execute("SELECT count(*) FROM sqlite_master WHERE name LIKE 'tbl_%'").fetchone(),
                             (len(lexicon.TABLES),))
            metadata = dict(connection.execute("SELECT key,value FROM dictionary_metadata"))
            self.assertEqual(metadata["weight_unit"], lexicon.FORMAT["weight_unit"])
            self.assertEqual(int(metadata["reference_mass"]), lexicon.FORMAT["reference_mass"])
        before = self.files()
        self.build(check=True)
        self.assertEqual(before, self.files())
        self.overlay([])
        with self.assertRaisesRegex(ValueError, "out of date"):
            self.build(check=True)
        self.assertEqual(before, self.files())

    def test_changed_or_invalid_sources_preserve_existing_database(self):
        self.build()
        before = self.files()
        for target, content in [(self.data / "base.gz", gzip.compress(b"changed", mtime=0)),
                                (self.root / "NOTICE", b"changed")]:
            original = target.read_bytes()
            target.write_bytes(content)
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                self.build()
            self.assertEqual(before, self.files())
            target.write_bytes(original)

    def test_readable_weights_include_public_edits_and_detect_stale_exports(self):
        self.overlay([dict(text="Apple", reading="apple", weight=40, reason="Synthetic weight correction"),
                      dict(text="appletree", reading="appletree", exclude=True, reason="Synthetic exclusion")])
        self.build()
        readable = self.data / "generated/weights.tsv"
        self.assertEqual(readable.read_text(), "text\treading\tweight\nApple\tapple\t40\nalpha\talpha\t5\n")
        self.build(check=True)
        readable.write_text("stale export\n")
        with self.assertRaisesRegex(ValueError, "Readable weights are out of date"):
            self.build(check=True)
        self.assertEqual(readable.read_text(), "stale export\n")

    def test_bad_public_edits_fail_without_replacing_outputs(self):
        self.build()
        before = self.files()
        entry = dict(text="Apple", reading="apple", weight=10, reason="Synthetic change")
        for entries in [[entry, entry], [dict(entry, weight=True)], [dict(entry, weight=-1)],
                        [dict(entry, weight=2**63)], [dict(entry, exclude=True)], [dict(entry, reading="ap")],
                        [dict(entry, text="two words")], [dict(entry, text="caf\u00e9", reading="caf\u00e9")],
                        [dict(entry, reason=" ")], [dict(entry, unexpected=1)],
                        [dict(entry, text="apple")]]:
            with self.subTest(entries=entries):
                self.overlay(entries)
                with self.assertRaises(ValueError):
                    self.build()
                self.assertEqual(before, self.files())

    def test_explicit_casing_correction_excludes_the_old_identity(self):
        self.overlay([dict(text="Apple", reading="apple", exclude=True, reason="Synthetic old-case exclusion"),
                      dict(text="apple", reading="apple", weight=20, reason="Synthetic canonical case")])
        self.build()
        with sqlite3.connect(self.output / "si-english.sqlite") as connection:
            self.assertEqual(connection.execute("SELECT value,weight FROM tbl_1_a WHERE key='apple'").fetchall(),
                             [("apple", 20)])

    def test_semantic_check_accepts_sqlite_headers_but_rejects_schema_or_metadata_changes(self):
        self.build()
        database = self.output / "si-english.sqlite"
        manifest = self.output / "dictionary-manifest.json"

        def update_hash():
            value = json.loads(manifest.read_text())
            value["runtime_sha256"] = dictionary.digest(database.read_bytes())
            manifest.write_text(json.dumps(value))

        raw = bytearray(database.read_bytes())
        raw[96:100] = (3040000).to_bytes(4, "big")
        database.write_bytes(raw)
        update_hash()
        self.build(check=True)
        for statement in ["DROP INDEX idx_key_tbl_1_a",
                          "UPDATE dictionary_metadata SET value='different-unit' WHERE key='weight_unit'"]:
            self.build()
            with sqlite3.connect(database) as connection:
                connection.execute(statement)
            update_hash()
            with self.assertRaisesRegex(ValueError, "out of date"):
                self.build(check=True)

    def test_rejects_unrecognized_weight_contract(self):
        lock = self.data / "sources.lock.json"
        value = json.loads(lock.read_text())
        value["dictionary_format"]["reference_mass"] += 1
        lock.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "dictionary format"):
            self.build()
        self.assertFalse((self.output / "si-english.sqlite").exists())


class EnglishSnapshotTests(unittest.TestCase):
    def test_retained_snapshot_preserves_spellings_and_uses_the_pinned_chinese_reference_unit(self):
        root = Path(__file__).resolve().parents[2]
        data = root / "Data/English/SI"
        lock = json.loads((data / "sources.lock.json").read_text())
        outputs, summary = dictionary.vocabulary.compile_vocabulary(root)
        words = [line.split("\t")[0] for line in outputs[dictionary.vocabulary.MERGED].decode().splitlines()[1:]]
        frequencies = [10 ** (-value / 100) for value in dictionary.ranking.frequency_bins(words)]
        total = math.fsum(frequencies) + 1e-9
        self.assertEqual(lock["bootstrap"]["vocabulary_words_sha256"], summary["words_sha256"])
        raw = gzip.decompress((data / lock["sources"][0]["path"]).read_bytes())
        self.assertEqual(dictionary.digest(raw), lock["sources"][0]["sha256"])
        rows = [line.split("\t") for line in raw.decode().splitlines() if not line.startswith("#")]
        self.assertEqual([row[0] for row in rows], words)
        self.assertEqual([int(row[2]) for row in rows],
                         [max(1, round(value / total * lexicon.FORMAT["reference_mass"])) for value in frequencies])
        # Integer rounding is bounded, rather than a claim that these are shared corpus counts.
        self.assertLessEqual(abs(sum(int(row[2]) for row in rows) + lock["unknown_weight"]
                                 - lexicon.FORMAT["reference_mass"]), (len(rows) + 1) / 2)
        self.assertFalse((root / "mac/SI/Core/EnglishLexiconData.swift").exists())
        self.assertFalse((root / "mac/SI/Core/EnglishFrequencyData.swift").exists())


if __name__ == "__main__":
    unittest.main()
