"""Materialize two pinned batches of syllable-labeled training examples."""

import argparse
from collections import Counter, defaultdict
import csv
from pathlib import Path
import re
import tempfile

from ..common import file_hash, fingerprint, normalized, write_json


REPO = Path(__file__).resolve().parents[3]
SOURCE = Path("Data/Chinese/base.csv")
SOURCE_REVISION = "c60f79922b6340864e394df1d486d33fde75b6bd"
SOURCE_SHA256 = "18adf68c6cf5ef53cf7425459455fbe88a94d241c12f836c18713c733f2edf90"
FIRST_BATCH_REVISION = "pinyin-syllable-50k-v1"
DATASET_REVISION = "pinyin-syllable-100k-v1"
HAN = re.compile(r"[\u4e00-\u9fff]{1,14}")
READING = re.compile(r"[a-z]+(?:'[a-z]+)*")
LEXICAL_QUOTAS = {1: 3500, 2: 20000, 3: 12500, 4: 6000, 6: 3000}
ADDITIONAL_LEXICAL_QUOTAS = {2: 18000, 3: 15000, 4: 9500, 6: 2500}
CONTEXT_QUOTA = 5000
HELD_OUT_ROWS = 1000


def read_lexicon(source):
    if file_hash(source) != SOURCE_SHA256:
        raise ValueError(f"Use the pinned {SOURCE} at {SOURCE_REVISION}")
    with source.open(encoding="utf-8", newline="") as stream:
        entries = {}
        for row in csv.DictReader(stream):
            text, reading, weight = row["text"], row["reading"], int(row["weight"])
            if not HAN.fullmatch(text) or not READING.fullmatch(reading) or weight <= 0:
                continue
            syllables = tuple(reading.split("'"))
            if len(syllables) == len(text):
                entries[text, syllables] = weight
    return entries


def select_rows(entries, ranked, quotas, previous=()):
    rows = []
    paths = defaultdict(set)
    previous_inputs = {normalized(spelling) for spelling, _, _, _ in previous}
    previous_targets = {normalized(target) for _, target, _, _ in previous}
    previous_phrases = {normalized(context + target) for _, target, context, _ in previous if context}

    def add(target, syllables, context=""):
        spelling = "".join(syllables)
        target_key = normalized(target)
        if (spelling in previous_inputs or target_key in previous_targets
                or target_key in previous_phrases):
            return False
        path = " ".join(syllables)
        if path not in paths[spelling] and len(paths[spelling]) == 3:
            return False
        paths[spelling].add(path)
        rows.append((spelling, target, context, path))
        return True

    # Both halves must occur with the same readings in the source lexicon.
    # Use only one boundary and reading from a given longer source phrase.
    phrases = set()
    target_contexts = Counter(target for _, target, context, _ in previous if context)
    prefix_uses = Counter(context for _, _, context, _ in previous if context)
    for full, reading in ranked:
        if len(full) < 5 or full in phrases or len(set(full)) == 1:
            continue
        full_key = normalized(full)
        if full_key in previous_phrases or full_key in previous_targets:
            continue
        for size in (4, 3, 2, 5):
            prefix, target = full[:-size], full[-size:]
            if len(prefix) < 2 or target_contexts[target] >= 4 or prefix_uses[prefix] >= 20:
                continue
            if ((prefix, reading[:-size]) in entries and (target, reading[-size:]) in entries
                    and add(target, reading[-size:], prefix)):
                phrases.add(full)
                target_contexts[target] += 1
                prefix_uses[prefix] += 1
                break
        if len(phrases) == CONTEXT_QUOTA:
            break
    if len(phrases) != CONTEXT_QUOTA:
        raise ValueError(f"Only found {len(phrases)} contextual rows")

    counts = Counter()
    for target, reading in ranked:
        length = len(target)
        bucket = 6 if length == 5 else length
        if bucket not in quotas or target in phrases or counts[bucket] == quotas[bucket]:
            continue
        if add(target, reading):
            counts[bucket] += 1
    if counts != quotas:
        raise ValueError(f"Could not fill lexical quotas: {counts}")
    return rows


def split_rows(rows, revision):
    # Keep alternate readings and homophones together, including transitive ties.
    parents = list(range(len(rows)))

    def root(index):
        while index != parents[index]:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    owners = {}
    for index, row in enumerate(rows):
        for field, value in enumerate(row[:2]):
            owner = owners.setdefault((field, normalized(value)), index)
            parents[root(index)] = root(owner)
    groups = defaultdict(list)
    for index, row in enumerate(rows):
        groups[root(index)].append(row)

    result = {"train": [], "validation": [], "test": []}
    for group in sorted(groups.values(), key=lambda rows: fingerprint([revision, rows])):
        destination = "train"
        if all(len(target) > 1 for _, target, _, _ in group):
            # Keep validation/test balanced as complete groups fill each quota.
            split = min(("validation", "test"), key=lambda name: len(result[name]))
            if len(result[split]) + len(group) <= HELD_OUT_ROWS:
                destination = split
        result[destination].extend(group)
    if any(len(result[split]) != HELD_OUT_ROWS for split in ("validation", "test")):
        raise ValueError("Could not reach exact held-out sizes with grouped rows")
    return {split: sorted(records) for split, records in result.items()}


def build(source, output):
    if output.exists():
        raise ValueError("Use a new output directory")
    entries = read_lexicon(source)
    ranked = sorted(entries, key=lambda entry: (-entries[entry], *entry))
    first = select_rows(entries, ranked, LEXICAL_QUOTAS)
    additional = select_rows(entries, ranked, ADDITIONAL_LEXICAL_QUOTAS, first)
    batches = {
        "examples.csv": split_rows(first, FIRST_BATCH_REVISION),
        "additional.csv": split_rows(additional, DATASET_REVISION),
    }
    counts = {split: {"rows": 0, "with_context": 0} for split in batches["examples.csv"]}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".syllable-csv-", dir=output.parent) as temporary:
        staged = Path(temporary) / "collection"
        hashes = {}
        batch_counts = {}
        for filename, splits in batches.items():
            batch_counts[filename] = {}
            for split, rows in splits.items():
                name = f"{split}/{filename}"
                path = staged / name
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("w", encoding="utf-8", newline="") as stream:
                    writer = csv.writer(stream, lineterminator="\n")
                    writer.writerow(("input", "target", "context", "syllables"))
                    writer.writerows(rows)
                hashes[name] = file_hash(path)
                count = {"rows": len(rows), "with_context": sum(bool(row[2]) for row in rows)}
                batch_counts[filename][split] = count
                for key, value in count.items():
                    counts[split][key] += value
        write_json(staged / "provenance.json", {
            "schema_version": 1,
            "default": {
                "license": "CC-BY-4.0",
                "origin": ("Selected and adapted from SI Data/Chinese/base.csv. Wanxiang base vocabulary by "
                           "amzxyz and rime-wanxiang-data contributors; SI lexical additions and review. "
                           "See the dataset guide and bundled SI vocabulary notices."),
                "revision": DATASET_REVISION,
            },
            "files": {f"{split}/examples.csv": {"revision": FIRST_BATCH_REVISION} for split in counts},
            "materialization": {
                "source": SOURCE.as_posix(),
                "si_revision": SOURCE_REVISION,
                "source_sha256": SOURCE_SHA256,
                "wanxiang_revision": "adfa047c339627737f0a4c75674a8042c1ef7f72",
                "counts": counts,
                "batches": batch_counts,
                "csv_sha256": hashes,
            },
        })
        staged.rename(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=REPO / SOURCE)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.source, args.output)


if __name__ == "__main__":
    main()
