"""Bounded keyboard errors, generated after the clean corpus has been split."""

import random

from .common import fingerprint

KEY_ROWS = ("qwertyuiop", "asdfghjkl", "zxcvbnm")
NEIGHBORS = {}
for row_number, row in enumerate(KEY_ROWS):
    for column, letter in enumerate(row):
        NEIGHBORS[letter] = "".join(
            c for r, letters in enumerate(KEY_ROWS) for i, c in enumerate(letters)
            if abs(r - row_number) <= 1 and abs(i - column) <= 1 and c != letter
        )


def corrupt(text, rng, kind):
    positions = [i for i, c in enumerate(text) if c.lower() in NEIGHBORS]
    if not positions:
        return text
    if kind == "transpose":
        positions = [i for i in positions if i + 1 < len(text) and text[i + 1].lower() in NEIGHBORS
                     and text[i] != text[i + 1]]
        if not positions:
            return text
    i = rng.choice(positions)
    if kind == "delete":
        return text[:i] + text[i + 1:] if len(text) > 1 else text
    if kind == "insert":
        return text[:i] + text[i] + text[i:]
    if kind == "substitute":
        c = rng.choice(NEIGHBORS[text[i].lower()])
        return text[:i] + (c.upper() if text[i].isupper() else c) + text[i + 1:]
    if kind == "transpose":
        return text[:i] + text[i + 1] + text[i] + text[i + 2:]
    raise ValueError("Unknown noise kind")


def variants(row, seed, count, max_edits):
    rng = random.Random(fingerprint([seed, row["input"], row["target"], row["language"]]))
    kinds = ["delete", "insert", "substitute", "transpose"]
    rng.shuffle(kinds)
    seen = {row["input"]}
    emitted = 0
    if not max_edits or not count:
        return
    for attempt in range(max(16, count * 8)):
        text = row["input"]
        applied = []
        for edit in range(rng.randint(1, max_edits)):
            kind = kinds[(attempt + edit) % len(kinds)]
            changed = corrupt(text, rng, kind)
            if changed != text:
                applied.append(kind)
                text = changed
        if text and text not in seen:
            seen.add(text)
            emitted += 1
            yield {**row, "input": text, "noise": "+".join(applied), "clean_input": row["input"]}
            if emitted >= count:
                return
