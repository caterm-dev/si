"""Build SI-authored common Chinese vocabulary and short synthetic chat pairs."""

import argparse
import itertools
import re
import shutil
import tempfile
from collections import Counter
from pathlib import Path

import pypinyin
from pypinyin import lazy_pinyin, load_phrases_dict

from .common import file_hash, fingerprint, read_json, write_json, write_jsonl

DEFAULT_SEED = Path(__file__).parent / "data/chinese-starter/seed.json"


def build(seed_path, output):
    seed_path, output = Path(seed_path), Path(output)
    seed = read_json(seed_path)
    if seed.get("schema_version") != 1 or not 2 <= seed["max_characters"] <= 24:
        raise ValueError("Unsupported seed schema or short-utterance limit")
    if output.exists():
        raise ValueError("Corpus output already exists; choose a new version")
    if pypinyin.__version__ != "0.55.0":
        raise ValueError("Corpus generation requires pinned pypinyin 0.55.0")
    overrides = seed["pronunciations"]
    for text, spelling in overrides.items():
        syllables = spelling.split()
        if len(syllables) != len(text) or not all(re.fullmatch("[a-z]+", s) for s in syllables):
            raise ValueError("Pronunciation overrides require one lowercase syllable per Han character")
    load_phrases_dict({text: [[s] for s in spelling.split()] for text, spelling in overrides.items() if len(text) > 1})
    records = {}

    def add(text, kind, category, group, reading=None):
        if not re.fullmatch(r"[\u3400-\u9fff]+", text) or not 1 <= len(text) <= seed["max_characters"]:
            raise ValueError(f"Invalid or oversized Chinese utterance in {category}")
        spelling = (reading or overrides.get(text) or " ".join(lazy_pinyin(text))).replace(" ", "").replace("ü", "v")
        if not re.fullmatch("[a-z]+", spelling):
            raise ValueError(f"Unconverted pronunciation in {category}")
        row = {"input": spelling, "target": text, "language": "zh", "kind": kind,
               "category": category, "group_id": group}
        # Retain overlapping group memberships so prepare can merge related families.
        records[(spelling, text, group)] = row

    words = set()
    for category, entries in seed["words"].items():
        for text in entries:
            words.add(text)
            add(text, "word", category, "word:" + text)
    for text, readings in seed.get("alternate_pronunciations", {}).items():
        if text not in words:
            raise ValueError("Alternate pronunciation has no vocabulary entry")
        for spelling in readings:
            add(text, "word", "alternate_reading", "word:" + text, spelling)
    for category, entries in seed["chat"].items():
        for text in entries:
            add(text, "chat", category, "chat:" + text)
    template_ids = set()
    for template in seed["templates"]:
        if template["id"] in template_ids:
            raise ValueError("Duplicate template ID")
        template_ids.add(template["id"])
        names = list(template["slots"])
        for values in itertools.product(*(template["slots"][name] for name in names)):
            substitutions = dict(zip(names, values))
            text = template["pattern"].format(**substitutions)
            group = "template:" + fingerprint([template.get("family", template["id"]),
                                               [substitutions[key] for key in template["group_by"]]])
            add(text, "template", template["id"], group)
    ordered = [records[key] for key in sorted(records)]
    pairs = {(r["input"], r["target"]) for r in ordered}
    outputs = {r["target"] for r in ordered}
    summary = {
        "schema_version": 1, "seed_sha256": file_hash(seed_path),
        "generator_sha256": file_hash(__file__), "pypinyin_version": pypinyin.__version__,
        "source_rows": len(ordered), "unique_pairs": len(pairs), "unique_outputs": len(outputs),
        "unique_words": len(words),
        "unique_chat_outputs": len({r["target"] for r in ordered if r["kind"] != "word"}),
        "maximum_output_characters": max(map(len, outputs)),
        "rows_by_kind": dict(Counter(r["kind"] for r in ordered)),
        "rows_by_category": dict(Counter(r["category"] for r in ordered)),
        "quality": "Original synthetic starter corpus; not real conversations or a frequency-ranked language benchmark.",
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".corpus-", dir=output.parent))
    try:
        write_jsonl(staging / "pairs.jsonl", ordered)
        write_json(staging / "summary.json", summary)
        write_json(staging / "sources.json", {"schema_version": 1, "sources": [{
            "id": "si-chinese-starter-v1", "path": "pairs.jsonl", "sha256": file_hash(staging / "pairs.jsonl"),
            "license": "GPL-3.0-only", "origin": "SI-authored vocabulary, short messages and phrase templates; no conversation logs",
            "revision": fingerprint(summary), "format": "pairs",
        }]})
        (staging / "NOTICE.md").write_text(
            "# SI Chinese starter data\n\nVocabulary, short messages and templates are original SI-authored synthetic material under GPLv3.\n"
            "Pronunciations are generated by pypinyin 0.55.0 (MIT), with seed-file overrides and alternate readings.\n"
            "Tool origin/license: https://github.com/mozillazg/python-pinyin/tree/v0.55.0\n"
            "No private input, chat logs, user dictionaries or downloaded corpus is included.\n"
            "This starter set does not establish broad vocabulary coverage or real-chat accuracy.\n", encoding="utf-8")
        shutil.copyfile(Path(__file__).resolve().parent.parent / "LICENSE", staging / "LICENSE")
        staging.rename(output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(build(args.seed, args.output))


if __name__ == "__main__":
    main()
