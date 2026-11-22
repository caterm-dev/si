#!/usr/bin/env python3
"""Evaluate opt-in Pinyin suggestions against synthetic typos and clean inputs."""

import argparse
from collections import Counter
from contextlib import ExitStack
import csv
import json
import math
from pathlib import Path
import random
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
VOCABULARY = ROOT / "Data/Chinese"
KINDS = ("missing", "swap", "neighbor")
KEY_ROWS = ("qwertyuiop", "asdfghjkl", "zxcvbnm")
KEY_POSITIONS = {
    letter: (row, column * 2 + row)
    for row, keys in enumerate(KEY_ROWS)
    for column, letter in enumerate(keys)
}
CLEAN_CONTROLS = (
    "hello", "SwiftUI", "snake_case", "v2", "foo.bar", "chang'an",
    "openai", "jsonparser", "devtools", "fastapi", "websocket", "openjdk",
)
KEYSTROKE_SEQUENCES = (
    "nihao", "nihoa", "rengongzhineng", "rengognzhineng",
    "womenjintianqugongyuan", "womenjintainqugongyuan", "hello", "SwiftUI",
)


def readings(vocabulary, length_band):
    """Pick the most frequent maintained word for each compact spelling."""
    words = {}
    minimum, maximum, max_spelling = (5, 7, 36) if length_band == "long" else (2, 4, 18)
    with (VOCABULARY / f"{vocabulary}.csv").open(encoding="utf-8", newline="") as source:
        for row in csv.DictReader(source):
            word, reading = row["text"], row["reading"]
            syllables = tuple(reading.split("'"))
            if (
                not minimum <= len(word) <= maximum
                or not re.fullmatch(r"[\u4e00-\u9fff]+", word)
                or len(syllables) != len(word)
                or not all(re.fullmatch(r"[a-z]+", syllable) for syllable in syllables)
                or not 4 <= sum(map(len, syllables)) <= max_spelling
            ):
                continue
            key = "".join(syllables)
            value = (int(row["weight"]), word, syllables)
            if key not in words or value > words[key]:
                words[key] = value
    return sorted(words.values(), reverse=True)


def neighbors(letter, cross_row):
    row, column = KEY_POSITIONS[letter]
    if cross_row:
        return [key for key, (other_row, other_column) in KEY_POSITIONS.items()
                if abs(row - other_row) == 1 and abs(column - other_column) <= 2]
    return [key for key, (other_row, other_column) in KEY_POSITIONS.items()
            if row == other_row and 0 < abs(column - other_column) <= 2]


def edits(syllables, kind, separator, cross_row):
    clean = "".join(syllables)
    results = {}
    for index, syllable in enumerate(syllables):
        for offset, letter in enumerate(syllable):
            removed = 1
            if kind == "missing":
                replacements = ("",) if len(syllable) > 1 else ()
            elif kind == "swap":
                pair = syllable[offset:offset + 2]
                removed = 2
                replacements = (pair[::-1],) if len(pair) == 2 and pair[0] != pair[1] else ()
            else:
                replacements = neighbors(letter, cross_row)
            for replacement in replacements:
                edited = syllable[:offset] + replacement + syllable[offset + removed:]
                parts = (*syllables[:index], edited, *syllables[index + 1:])
                compact = "".join(parts)
                if len(compact) >= 4 and not clean.startswith(compact):
                    results.setdefault(compact, parts)
    return [separator.join(results[compact]) for compact in sorted(results)]


def cases(args):
    rng = random.Random(args.seed)
    pool = readings(args.vocabulary, args.length_band)[args.offset:args.offset + 800]
    if len(pool) < args.samples:
        raise ValueError("The requested vocabulary band is too small")
    selected = rng.sample(pool, args.samples)
    separator = "'" if args.explicit_boundaries else ""
    for index, (_, word, syllables) in enumerate(selected):
        kind = KINDS[index % len(KINDS)]
        possible = edits(syllables, kind, separator, args.cross_row_neighbors)
        if possible:
            yield "clean", separator.join(syllables), word
            yield kind, rng.choice(possible), word
    for spelling in CLEAN_CONTROLS:
        yield "control", spelling, None


def candidates(process, spelling):
    started = time.perf_counter()
    process.stdin.write(spelling + "\n")
    process.stdin.flush()
    rows = []
    for line in process.stdout:
        if line == "\n":
            return rows, (time.perf_counter() - started) * 1_000
        language, count, kind, score, text = line.rstrip("\n").split("\t", 4)
        rows.append((language, int(count), kind, score, text))
    raise RuntimeError(f"si-cli ended before returning a result for {spelling!r}")


def percentile(samples, fraction):
    return round(sorted(samples)[math.ceil(len(samples) * fraction) - 1], 2)


def compare(sessions, spelling, index, timings):
    rows = [[], []]
    for mode in (index % 2, 1 - index % 2):
        rows[mode], elapsed = candidates(sessions[mode], spelling)
        timings[mode].append(elapsed)
    ordinary = [row for row in rows[1] if row[2] != "correction"]
    if ordinary != rows[0]:
        raise ValueError(f"Ordinary candidates changed for {spelling!r}")
    consumed_bytes = len(spelling.encode("utf-8"))
    if not ordinary or ordinary[-1] != ("literal", consumed_bytes, "literal", "", spelling):
        raise ValueError(f"Literal fallback missing for {spelling!r}")
    suggestions = [row for row in rows[1] if row[2] == "correction"]
    if len(suggestions) > 4 or any(row[1] != consumed_bytes for row in suggestions):
        raise ValueError(f"Invalid correction count or span for {spelling!r}")
    return ordinary, [row[-1] for row in suggestions], consumed_bytes


def latency(timings):
    result = {
        mode: {"p50": percentile(times, 0.5), "p95": percentile(times, 0.95)}
        for mode, times in zip(("off", "on"), timings)
    }
    deltas = [on - off for off, on in zip(*timings, strict=True)]
    result["on_minus_off"] = {
        "p50": percentile(deltas, 0.5),
        "p95": percentile(deltas, 0.95),
    }
    return result


def evaluate(args):
    command = [
        str(args.cli.resolve()), "candidates", str(args.lexicon.resolve()),
        "--search", args.search, "--languages", args.languages,
    ]
    if args.grams is not None:
        command.extend(("--grams", str(args.grams.resolve())))
    if args.preceding is not None:
        command.extend(("--preceding", args.preceding))
    metrics = {kind: Counter(cases=0, suggested=0, ordinary_target=0, ordinary_top4=0, top1=0, top4=0)
               for kind in ("clean", "control", *KINDS)}
    missed = {kind: Counter(with_ordinary_chinese=0, without_ordinary_chinese=0)
              for kind in KINDS}
    timings = [[], []]
    errors = []
    with ExitStack() as stack:
        sessions = [
            stack.enter_context(subprocess.Popen(
                [*command, "--pinyin-correction", mode],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8",
            ))
            for mode in ("off", args.correction_mode)
        ]
        for session in sessions:
            candidates(session, "nihao")
        for index, (kind, spelling, expected) in enumerate(cases(args)):
            ordinary, texts, consumed_bytes = compare(sessions, spelling, index, timings)
            ordinary_rank = next(
                (rank for rank, row in enumerate(ordinary, 1)
                 if row[1] == consumed_bytes and row[-1] == expected),
                None,
            )
            ordinary_top4 = ordinary_rank is not None and ordinary_rank <= 4
            target_suggested = expected in texts
            metrics[kind].update(
                cases=1,
                suggested=bool(texts),
                ordinary_target=ordinary_rank is not None,
                ordinary_top4=ordinary_top4,
                top1=bool(texts and texts[0] == expected),
                top4=target_suggested,
            )
            if kind in missed and not target_suggested and not ordinary_top4:
                has_ordinary_chinese = any(
                    row[:3] == ("zh-Hans", consumed_bytes, "exact") for row in ordinary
                )
                bucket = "with_ordinary_chinese" if has_ordinary_chinese else "without_ordinary_chinese"
                missed[kind][bucket] += 1
            if args.show_errors and (
                (kind in ("clean", "control") and texts)
                or (kind in missed and not target_suggested and not ordinary_top4)
            ):
                errors.append({
                    "kind": kind,
                    "spelling": spelling,
                    "expected": expected,
                    "suggestions": texts,
                    "ordinary_first": ordinary[0][-1],
                })
        prefix_timings = [[], []]
        if args.search == "preview":
            prefixes = (source[:length] for source in KEYSTROKE_SEQUENCES
                        for length in range(1, len(source) + 1))
            for index, prefix in enumerate(prefixes):
                compare(sessions, prefix, index, prefix_timings)
        stress = []
        if args.stress:
            for repetitions in (10, 20, 25):
                expected = "你好" * repetitions
                for kind, final in (("clean", "nihao"), ("typo", "nihoa")):
                    spelling = "nihao" * (repetitions - 1) + final
                    samples = [[], []]
                    for iteration in range(8):
                        _, suggestions, _ = compare(sessions, spelling, iteration, samples)
                    stress.append({
                        "normalized_letters": len(spelling),
                        "kind": kind,
                        "suggestions": len(suggestions),
                        "expected_in_suggestions": expected in suggestions,
                        "cli_latency_ms": latency(samples),
                    })
        for session in sessions:
            session.stdin.close()
            if session.wait() != 0:
                raise RuntimeError("si-cli exited unsuccessfully")

    report = {
        "seed": args.seed,
        "requested_samples": args.samples,
        "vocabulary": args.vocabulary,
        "length_band": args.length_band,
        "vocabulary_offset": args.offset,
        "grams": args.grams is not None,
        "search": args.search,
        "languages": args.languages,
        "has_preceding_context": args.preceding is not None,
        "correction_mode": args.correction_mode,
        "explicit_boundaries": args.explicit_boundaries,
        "cross_row_neighbors": args.cross_row_neighbors,
        "cases": metrics,
        "target_misses": missed,
        "cli_latency_ms": latency(timings),
    }
    if prefix_timings[0]:
        report["keystroke_preview"] = {
            "prefixes": len(prefix_timings[0]),
            "cli_latency_ms": latency(prefix_timings),
        }
    if args.stress:
        report["stress"] = stress
    if args.show_errors:
        report["errors"] = errors
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "target/release/si-cli")
    parser.add_argument("--lexicon", type=Path, default=ROOT / "Data/Engine/main.silex")
    parser.add_argument("--grams", type=Path)
    parser.add_argument("--correction-mode", choices=("on", "higher-recall"), default="on")
    parser.add_argument("--search", choices=("full", "preview"), default="full")
    parser.add_argument("--languages", choices=("zh-Hans,en", "zh-Hans"), default="zh-Hans,en")
    parser.add_argument("--preceding", help="Use the same synthetic preceding text for both modes")
    parser.add_argument("--explicit-boundaries", action="store_true")
    parser.add_argument("--cross-row-neighbors", action="store_true")
    parser.add_argument("--show-errors", action="store_true")
    parser.add_argument("--stress", action="store_true")
    parser.add_argument("--samples", type=int, default=80)
    parser.add_argument("--length-band", choices=("short", "long"), default="short")
    parser.add_argument("--seed", type=int, default=1763)
    parser.add_argument("--vocabulary", choices=sorted(path.stem for path in VOCABULARY.glob("*.csv")),
                        default="base")
    parser.add_argument("--offset", type=int, default=0, help="Skip this many frequency-ranked readings")
    args = parser.parse_args()
    if not 1 <= args.samples <= 800 or args.offset < 0:
        parser.error("--samples must be 1 to 800 and --offset must be nonnegative")
    print(json.dumps(evaluate(args), indent=2))


if __name__ == "__main__":
    main()
