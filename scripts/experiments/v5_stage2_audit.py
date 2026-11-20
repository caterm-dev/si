#!/usr/bin/env python3
"""Inventory context metadata and schema fields in synthetic ranking query files."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

from v5_probability_audit import ROOT, pipeline

CONTEXT_FIELDS = {
    'previous_commit_language': {'previouscommitlanguage', 'previoussubmittedlanguage',
                                 'previoussegmentlanguage', 'lastcommitlanguage',
                                 'lastsegmentlanguage', 'previouslanguage'},
    'app_category': {'appcategory', 'hostappcategory', 'applicationcategory'},
    'bundle_id': {'bundleid', 'bundleidentifier', 'appbundleid', 'hostbundleid'},
    'control_type': {'controltype', 'fieldtype', 'hostcontroltype', 'inputcontroltype'},
    'per_control_languages': {'percontrollanguages', 'controllanguages', 'fieldlanguages',
                              'controlenabledlanguages', 'percontrollanguageconfiguration'},
}


def values_in(row):
    """Yield schema paths, including nested objects occurring in arrays."""
    for key, value in row.items():
        yield key, value
        children = value if isinstance(value, list) else [value]
        for child in children:
            if isinstance(child, dict):
                yield from ((f'{key}.{name}', item) for name, item in values_in(child))


def audit(path):
    fields, nonempty, languages, choices, known = (Counter() for _ in range(5))
    requested_counts = Counter()
    requested_values = {name: Counter() for name in CONTEXT_FIELDS}
    count = 0
    with path.open() as stream:
        for line in stream:
            row = json.loads(line)
            count += 1
            present, supplied, requested = set(), set(), set()
            for key, value in values_in(row):
                present.add(key)
                if value in (None, '', [], {}):
                    continue
                supplied.add(key)
                short = re.sub(r'[^a-z]', '', key.rsplit('.', 1)[-1].lower())
                for name, aliases in CONTEXT_FIELDS.items():
                    if short in aliases:
                        requested.add(name)
                        requested_values[name][json.dumps(value, ensure_ascii=False, sort_keys=True)] += 1
            fields.update(present)
            nonempty.update(supplied)
            requested_counts.update(requested)
            languages.update([','.join(row['languages']) if row.get('languages') else '(missing)'])
            choices.update(choice['language'] for choice in row.get('prior_choices', []) if 'language' in choice)
            known.update([str(row['context_available']) if 'context_available' in row else '(missing)'])
    return {
        'queries': count, 'fields': {key: {'present': fields[key], 'nonempty': nonempty[key]}
                                     for key in sorted(fields)},
        'requested_fields': {name: {'nonempty': requested_counts[name],
                                    'coverage': requested_counts[name] / count,
                                    'distribution': dict(requested_values[name])}
                             for name in CONTEXT_FIELDS},
        'query_languages': dict(languages), 'prior_choice_languages': dict(choices),
        'context_available': dict(known),
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    data = pipeline.DATA
    paths = [data / 'train.jsonl', data / 'validation.jsonl',
             *sorted((data / 'generated').glob('*/*.jsonl'))]
    for name in ('neural-v5-learning-curve-20261120', 'full-200k-plus-60k-v5-20261120'):
        snapshot = data / 'runs' / name / 'train.jsonl'
        if snapshot.is_file():
            paths.append(snapshot)
    with args.output.open('x') as output:
        json.dump({str(path.relative_to(ROOT)): audit(path) for path in paths},
                  output, indent=2, ensure_ascii=False, allow_nan=False)
        output.write('\n')
