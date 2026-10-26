"""Compare reports only when their data, split, cases and top-k definition agree."""

import argparse

from .common import read_json


def compare(paths):
    reports = [read_json(path) for path in paths]
    if len(reports) < 2:
        raise ValueError("At least two reports are required")
    reference = reports[0]
    for report in reports[1:]:
        if any(report[key] != reference[key] for key in ("dataset_id", "split", "evaluation_scope", "total_cases", "evaluated_cases")) or report["metrics"]["k"] != reference["metrics"]["k"]:
            raise ValueError("Reports have different datasets, splits, evaluated cases or k")
    return [{"report": str(path), "partial": report["partial"], **report["metrics"]["overall"]}
            for path, report in zip(paths, reports)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", help="JSON reports from evaluate/test")
    args = parser.parse_args()
    for row in compare(args.reports):
        print(row)


if __name__ == "__main__":
    main()
