#!/usr/bin/env python3
"""Audit frozen ranking recall and construct a separate English compound guard set."""
import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import re

from prepare_kenlm_ranking import HAN, HELDOUT, RESOURCES, SPELLING, clauses, lexemes, sha, write_rows

CHINESE = RESOURCES / "Chinese/si-pinyin.sqlite"
ENGLISH = RESOURCES / "English/si-english.sqlite"
BUCKETS = ("1–8", "9–16", "17–32", "33+")
REASONS = (
    "missing_dictionary_word", "incompatible_reading", "search_pruning", "decoder_limits",
)


def read_rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def verify(dataset, files):
    manifest = json.loads((dataset / "manifest.json").read_text(encoding="utf-8"))
    for path, expected in files(manifest).items():
        if sha(path) != expected:
            raise ValueError(f"Frozen source hash mismatch for {path}")
    return manifest


def alternate_word_path(gold, spelling, readings):
    """Check an exact dictionary path without the decoder's cut and span budgets."""
    reachable = [{0}] + [set() for _ in gold]
    for start, positions in enumerate(reachable[:-1]):
        if positions:
            for end in range(start + 1, len(gold) + 1):
                for _, key in readings.get(gold[start:end], ()):
                    for position in positions:
                        if spelling.startswith(key, position):
                            reachable[end].add(position + len(key))
    return len(spelling) in reachable[-1]


def recall(dataset, probe_path, output):
    manifest = verify(dataset, lambda m: {
        dataset / "test.jsonl": m["files"]["test.jsonl"], HELDOUT: m["heldout_sha256"],
        CHINESE: m["chinese_dictionary_sha256"],
    })
    queries = {row["id"]: row for row in read_rows(dataset / "test.jsonl") if row["kind"] == "whole"}
    probe = {row["id"]: row for row in json.loads(probe_path.read_text())}
    if queries.keys() != probe.keys():
        raise ValueError("Probe IDs differ from frozen whole clauses")
    missing = [queries[key] for key, row in probe.items() if not row["reachable"]]
    source_ids = {int(row["id"].split("/")[0].removeprefix("zh-")): row for row in missing}
    source_pieces = {}
    wanted = set()
    with HELDOUT.open(encoding="utf-8") as source:
        for line_id, line in enumerate(source, 1):
            if row := source_ids.get(line_id):
                gold = row["expected"]
                pieces = [p for p in clauses(line.split()) if "".join(p) == gold and all(HAN.fullmatch(x) for x in p)]
                if not pieces:
                    raise ValueError(f"Cannot recover original clause {row['id']}")
                source_pieces[row["id"]] = pieces
                wanted.update(word for part in pieces for word in part)
                wanted.update(gold)
                if probe[row["id"]]["probe"] == "noPath":
                    wanted.update(gold[i:j] for i in range(len(gold)) for j in range(i + 1, len(gold) + 1))
    readings = defaultdict(set)
    dictionary_words = set()
    for key, text, weight in lexemes(CHINESE):
        if text not in wanted:
            continue
        dictionary_words.add(text)
        if SPELLING.fullmatch(key) and key.count("'") + 1 == len(text):
            readings[text].add((-weight, key))
    primary = {word: min(keys)[1] for word, keys in readings.items()}
    paths = {
        word: [(key, key.replace("'", "")) for key in sorted({key for _, key in keys})]
        for word, keys in readings.items()
    }

    def recover(query):
        for words in source_pieces[query["id"]]:
            keys = [primary.get(word) or "'".join(primary.get(char, "") for char in word) for word in words]
            if "".join(keys).replace("'", "") == query["input"]:
                return words, keys
        raise ValueError(f"Recovered gold reading differs for {query['id']}")

    examples = defaultdict(lambda: defaultdict(list))
    counts = {bucket: Counter(total=0, reachable=0) for bucket in BUCKETS}
    subreasons = defaultdict(Counter)
    polyphonic = Counter()
    dictionary_oov = Counter()
    cases = []
    for query in queries.values():
        bucket = query["bucket"]
        stats = counts[bucket]
        stats["total"] += 1
        native = probe[query["id"]]
        if native["bucket"] != bucket:
            raise ValueError(f"Probe bucket differs for {query['id']}")
        if native["reachable"]:
            stats["reachable"] += 1
            continue
        words, keys = recover(query)
        absent = [word for word in words if word not in dictionary_words]
        multiple = {word: sorted({k for _, k in readings[word]}) for word in words
                    if len({k for _, k in readings[word]}) > 1}
        polyphonic[bucket] += bool(multiple)
        dictionary_oov[bucket] += bool(absent)
        kind = native["probe"]
        if kind in {"inputLimit", "outputLimit"}:
            reason, detail = "decoder_limits", kind
        elif kind in {"inBoundedLattice", "lexicalRowLimit"}:
            reason, detail = "search_pruning", kind
        elif alternate_word_path(query["expected"], query["input"], paths):
            reason, detail = "decoder_limits", "dictionary_path_outside_decoder_cuts_or_span_limit"
        elif absent:
            reason, detail = "missing_dictionary_word", "missing_source_word_and_no_alternative_path"
        else:
            reason, detail = "incompatible_reading", "no_dictionary_path_matches_frozen_spelling"
        stats[reason] += 1
        subreasons[bucket][detail] += 1
        case = {
            "id": query["id"], "bucket": bucket, "expected": query["expected"], "input": query["input"],
            "words": words, "selected_readings": keys, "missing_words": absent, "polyphonic_words": multiple,
            "reason": reason, "detail": detail,
        }
        cases.append(case)
        examples[bucket][reason].append(case)
        examples["all"][reason].append(case)
    for bucket in BUCKETS:
        stats = counts[bucket]
        assert stats["total"] == stats["reachable"] + sum(stats[r] for r in REASONS)
    output.mkdir(parents=True, exist_ok=True)
    write_rows(output / "recall-cases.jsonl", cases)
    report = {
        "test_sha256": manifest["files"]["test.jsonl"], "buckets": counts, "subreasons": subreasons,
        "polyphonic_token_clauses": polyphonic, "clauses_with_missing_dictionary_words": dictionary_oov,
        "examples": {bucket: {r: groups.get(r, [])[:10] for r in REASONS}
                     for bucket, groups in examples.items()},
    }
    (output / "recall.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


def english(dataset, output, threshold):
    manifest = verify(dataset, lambda m: {
        ENGLISH: m["english_dictionary_sha256"], dataset / "english.jsonl": m["files"]["english.jsonl"],
    })
    entries = {}
    for key, text, weight in lexemes(ENGLISH):
        if re.fullmatch(r"[a-z]+", key) and text.lower() == key:
            previous = entries.get(key)
            if previous is None or (weight, text) > previous:
                entries[key] = (weight, text)
    audit = []
    queries = []
    guards = []
    for whole, (weight, text) in sorted(entries.items()):
        splits = [(whole[:i], whole[i:]) for i in range(1, len(whole))
                  if whole[:i] in entries and whole[i:] in entries]
        if not splits:
            continue
        queries.append({"id": whole, "input": whole, "expected": text, "context": [],
                        "kind": "english_compound", "bucket": "all"})
        for left, right in splits:
            a, b = entries[left][0], entries[right][0]
            audit.append((whole, text, weight, left, a, right, b, weight / max(1, a),
                          weight / max(1, b), max(1, weight) / (max(1, a) * max(1, b))))
        if weight > threshold and len(whole) >= 4 and text == whole:
            split = "dev" if hashlib.sha256(whole.encode()).digest()[0] < 154 else "test"
            guards.append({"id": f"en-{whole}/guard", "input": whole, "expected": text, "context": [],
                           "kind": "english_guard", "bucket": split})
    audit.sort(key=lambda row: (row[-1], row[0], row[3], row[5]))
    output.mkdir(parents=True, exist_ok=True)
    write_rows(output / "english-audit.jsonl", queries)
    write_rows(output / "english-guards.jsonl", guards)
    with (output / "english-splits.tsv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(["key", "word", "weight", "left", "left_weight", "right", "right_weight",
                         "ratio_left", "ratio_right", "ratio_product"])
        writer.writerows(audit)
    report = {
        "dictionary_sha256": manifest["english_dictionary_sha256"], "alphabetic_keys": len(entries),
        "compound_words": len(queries), "compound_splits": len(audit),
        "guard_weight_exclusive_threshold": threshold,
        "guards": dict(Counter(row["bucket"] for row in guards)),
    }
    (output / "english-audit-manifest.json").write_text(json.dumps(report, indent=2) + "\n")


def summarize_english(output):
    rows = json.loads((output / "english-audit.json").read_text(encoding="utf-8"))
    by_key = {row["input"]: row for row in rows}
    counts = {mode: Counter(row[mode]["outcome"] for row in rows) for mode in ("english", "bilingual")}
    case_variants = {
        mode: sum(row[mode]["outcome"] == "otherEnglish" and row[mode]["text"].lower() == row["input"]
                  for row in rows) for mode in counts
    }
    seen = set()
    with ((output / "english-splits.tsv").open(encoding="utf-8", newline="") as source,
          (output / "english-suspects-top200.tsv").open("w", encoding="utf-8", newline="") as target):
        reader = csv.DictReader(source, delimiter="\t")
        fields = [*reader.fieldnames, "english_top1", "english_outcome", "bilingual_top1", "bilingual_outcome"]
        writer = csv.DictWriter(target, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in reader:
            key = row["key"]
            if key in seen:
                continue
            seen.add(key)
            for mode in counts:
                winner = by_key[key][mode]
                row[f"{mode}_top1"] = winner["text"]
                row[f"{mode}_outcome"] = winner["outcome"]
            writer.writerow(row)
            if len(seen) == 200:
                break
    report = {"queries": len(rows), "counts": counts, "same_word_case_variants": case_variants}
    (output / "english-audit-summary.json").write_text(json.dumps(report, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    a = modes.add_parser("recall")
    a.add_argument("dataset", type=Path)
    a.add_argument("probe", type=Path)
    a.add_argument("output", type=Path)
    b = modes.add_parser("english")
    b.add_argument("dataset", type=Path)
    b.add_argument("output", type=Path)
    b.add_argument("--guard-weight", type=int, default=1000)
    modes.add_parser("summarize-english").add_argument("output", type=Path)
    args = parser.parse_args()
    if args.mode == "recall":
        recall(args.dataset, args.probe, args.output)
    elif args.mode == "english":
        english(args.dataset, args.output, args.guard_weight)
    else:
        summarize_english(args.output)


if __name__ == "__main__":
    main()
