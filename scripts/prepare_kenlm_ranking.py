#!/usr/bin/env python3
"""Freeze heldout-derived pinyin queries and a stratified English sample."""
import argparse
from collections import Counter, defaultdict
from functools import cache
import hashlib
import json
from pathlib import Path
import random
import re
import sqlite3
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
HELDOUT = ROOT / "corpus/chinese/generated/kenlm-selection-v1/data/heldout.txt"
RESOURCES = ROOT / "mac/SI/Core/Resources"
SEED = 20261106
STRICT = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]+(?: [\u3400-\u4dbf\u4e00-\u9fff]+)*")
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\U00020000-\U000323af]+")
SPELLING = re.compile(r"[a-zv]+(?:'[a-zv]+)*")
ASCII_LETTER = re.compile(r"[A-Za-z]")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def lexemes(path):
    with sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True) as db:
        for name, in db.execute("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name"):
            if re.fullmatch(r"tbl_[a-z0-9_]+", name):
                yield from db.execute(f"SELECT key, value, weight FROM {name}")


def readings(path):
    primary = {}
    ambiguous = set()
    for key, text, weight in lexemes(path):
        if not SPELLING.fullmatch(key) or key.count("'") + 1 != len(text):
            continue
        previous = primary.get(text)
        if previous is not None and previous[1] != key:
            ambiguous.add(text)
        item = (-weight, key)
        if previous is None or item < previous:
            primary[text] = item
    return primary, ambiguous


@cache
def punctuation(token):
    return bool(token) and all(unicodedata.category(s).startswith("P") for s in token)


def clauses(tokens):
    result = []
    start = 0
    for i, token in enumerate(tokens):
        if punctuation(token):
            if start < i:
                result.append(tokens[start:i])
            start = i + 1
    if start < len(tokens):
        result.append(tokens[start:])
    return result


def bucket(text):
    return "1–8" if len(text) <= 8 else "9–16" if len(text) <= 16 else "17–32" if len(text) <= 32 else "33+"


def query(group, kind, words, keys, context=()):
    expected = "".join(words)
    return {"id": f"{group}/{kind}", "input": "".join(keys).replace("'", ""),
            "expected": expected, "context": list(context), "kind": kind, "bucket": bucket(expected)}


def write_rows(path, rows):
    with path.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")


def prepare(stage, count):
    chinese = RESOURCES / "Chinese/si-pinyin.sqlite"
    english = RESOURCES / "English/si-english.sqlite"
    primary, ambiguous = readings(chinese)

    @cache
    def word_reading(word):
        if word in primary:
            return primary[word][1], False
        parts = [primary.get(char) for char in word]
        return ("'".join(part[1] for part in parts), True) if all(parts) else (None, False)

    def flags(text, tokens):
        return {"punctuation": any(unicodedata.category(c).startswith("P") for c in text),
                "digits": any(c.isdecimal() for c in text),
                "english": ASCII_LETTER.search(text) is not None,
                "polyphonic_single_character": any(len(word) == 1 and word in ambiguous for word in tokens)}

    removed = defaultdict(Counter)
    strict_removed = defaultdict(Counter)
    totals = Counter()
    eligible = []
    strict = []
    rng = random.Random(SEED)
    with HELDOUT.open(encoding="utf-8") as stream:
        for line_no, raw in enumerate(stream, 1):
            line = raw.rstrip("\n")
            tokens = line.split()
            totals["lines"] += 1
            pieces = clauses(tokens)
            han = [part for part in pieces if all(HAN.fullmatch(word) for word in part)]
            totals["clauses"] += len(pieces)
            totals["non_han_clauses"] += len(pieces) - len(han)
            readable = []
            for words in han:
                keyed = [word_reading(word) for word in words]
                if all(item[0] for item in keyed):
                    readable.append((words, [item[0] for item in keyed]))
                    totals["character_fallback_clauses"] += any(item[1] for item in keyed)
                else:
                    totals["missing_reading_clauses"] += 1
            if readable:
                eligible.append((line_no, *rng.choice(readable)))
            else:
                counter = removed["no_readable_clause" if han else "no_pure_han_clause"]
                counter["lines"] += 1
                counter.update(flags(line, tokens))

            if not STRICT.fullmatch(line):
                reason = "not_han_only_line"
            elif len(tokens) < 4:
                reason = "fewer_than_four_words"
            elif any(word not in primary or word in ambiguous for word in tokens):
                reason = "missing_or_nonunique_word_reading"
            else:
                strict.append(query(f"zh-{line_no}", "strict", tokens, [primary[word][1] for word in tokens]))
                continue
            strict_removed[reason]["lines"] += 1
            strict_removed[reason].update(flags(line, tokens))

    selected = rng.sample(eligible, count)
    # Co-locate duplicate gold strings and identical whole pinyin. Short query siblings
    # always follow their source clause. Common short spans can naturally repeat.
    parent = list(range(len(selected)))

    def root(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    seen = {}
    for i, (_, words, keys) in enumerate(selected):
        for key in (("text", "".join(words)), ("pinyin", "".join(keys).replace("'", ""))):
            j = seen.setdefault(key, i)
            parent[root(i)] = root(j)

    splits = {"dev": [], "test": []}
    split_sentences = Counter()
    for i, (line_no, words, keys) in enumerate(selected):
        group = f"zh-{line_no}"
        key = hashlib.sha256(f"{SEED}:{selected[root(i)][0]}".encode()).digest()
        split = "dev" if int.from_bytes(key[:8], "big") % 10 < 6 else "test"
        split_sentences[split] += 1
        length = rng.randint(1, min(len(words), 4))
        start = rng.randint(0, len(words) - length)
        end = start + length
        splits[split].append(query(group, "whole", words, keys))
        splits[split].append(query(group, "short_without_context", words[start:end], keys[start:end]))
        # Choose a noninitial span for the contextual track whenever a prefix exists.
        if start == 0 and len(words) > 1:
            length = min(length, len(words) - 1)
            start = rng.randint(1, len(words) - length)
            end = start + length
        if start > 0:
            splits[split].append(query(group, "paired_without_context", words[start:end], keys[start:end]))
            splits[split].append(query(group, "short_with_context", words[start:end], keys[start:end], words[:start]))

    english_strata = defaultdict(list)
    for key, text, weight in lexemes(english):
        if not re.fullmatch(r"[a-z]{4,}", key) or text.lower() != key:
            continue
        band = "0–9" if weight < 10 else "10–99" if weight < 100 else "100–999" if weight < 1000 else "1000–9999" if weight < 10000 else "10000+"
        english_strata[band].append((key, text, weight))
    english_rows = []
    for band in sorted(english_strata):
        words = sorted(english_strata[band])
        for key, text, _ in rng.sample(words, min(100, len(words))):
            prefix = key[:rng.randint(3, len(key) - 1)]
            for kind, spelling in (("english_whole", key), ("english_prefix", prefix)):
                english_rows.append({"id": f"en-{key}/{kind}", "input": spelling,
                                     "expected": text, "kind": kind, "bucket": band, "context": []})

    for name, rows in [*splits.items(), ("strict", strict), ("english", english_rows)]:
        write_rows(stage / f"{name}.jsonl", rows)

    def summary(counters):
        return {reason: {**values, "fraction_of_input_lines": values["lines"] / totals["lines"],
                         "feature_fractions": {name: value / values["lines"] for name, value in values.items()
                                               if name != "lines"}}
                for reason, values in counters.items()}

    audit = {"seed": SEED, "heldout_sha256": sha(HELDOUT), "chinese_dictionary_sha256": sha(chinese),
             "english_dictionary_sha256": sha(english), "totals": dict(totals),
             "eligible_lines": len(eligible), "sampled_clauses": count, "split_sentences": dict(split_sentences),
             "strict_lines": len(strict), "english_queries": len(english_rows),
             "excluded_lines": summary(removed), "strict_excluded_lines": summary(strict_removed),
             "files": {p.name: sha(p) for p in stage.glob("*.jsonl")}}
    (stage / "manifest.json").write_text(json.dumps(audit, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--count", type=int, default=20_000)
    args = parser.parse_args()
    expected = json.loads(HELDOUT.with_name("manifest.json").read_text())["splits"]["heldout"]["sha256"]
    if sha(HELDOUT) != expected:
        raise ValueError("Unexpected heldout bytes")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise FileExistsError(args.output)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as work:
        stage = Path(work) / "dataset"
        stage.mkdir()
        result = prepare(stage, args.count)
        stage.rename(args.output)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
