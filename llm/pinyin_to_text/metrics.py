"""Conversion metrics with multiple accepted outputs and explicit literal accounting."""

from collections import defaultdict


def edit_distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1]


def cases(rows):
    grouped = {}
    for row in rows:
        value = grouped.setdefault(row["input"], {"input": row["input"], "targets": set(), "languages": set(), "noise": set()})
        value["targets"].add(row["target"])
        value["languages"].add(row["language"])
        value["noise"].add(row["noise"])
    return list(grouped.values())


def summarize(observations, k):
    def aggregate(items):
        count = len(items)
        hits, recall, with_literal, distance, characters, copy_count, copy_errors = 0, 0, 0, 0, 0, 0, 0
        for case, prediction in items:
            outputs = prediction["model_candidates"]
            targets = case["targets"]
            first = outputs[0] if outputs else ""
            hits += first in targets
            recall += bool(set(outputs[:k]) & targets)
            with_literal += bool(set(prediction["candidates"]) & targets)
            reference = min(targets, key=lambda target: (edit_distance(first, target), target))
            distance += edit_distance(first, reference)
            characters += len(reference)
            # Ambiguous women -> {women, 我们} is not a false-correction fixture.
            if targets == {case["input"]} and "clean" in case["noise"]:
                copy_count += 1
                copy_errors += first != case["input"]
        return {
            "cases": count, "top1_accuracy": hits / count if count else None,
            "top_k_recall": recall / count if count else None,
            "candidate_recall_with_literal": with_literal / count if count else None,
            "character_error_rate": distance / characters if characters else None,
            "clean_copy_cases": copy_count,
            "clean_copy_error_rate": copy_errors / copy_count if copy_count else None,
        }

    buckets = defaultdict(list)
    for case, prediction in observations:
        buckets["language/" + "+".join(sorted(case["languages"]))].append((case, prediction))
        for kind in case["noise"]:
            buckets["noise/" + kind].append((case, prediction))
    return {"k": k, "overall": aggregate(observations),
            "buckets": {key: aggregate(items) for key, items in sorted(buckets.items())}}
