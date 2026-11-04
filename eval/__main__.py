"""Validate suites, export blind requests and score/compare model predictions."""

import argparse
import json

from .datasets import ROOT, TASKS, load, read_json, requests, write_new
from .scoring import compare, score


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('validate')
    for command in ('export', 'baseline', 'score'):
        sub = commands.add_parser(command)
        sub.add_argument('--task', required=True, choices=TASKS)
        sub.add_argument('--suite')
        sub.add_argument('--split', choices=('dev', 'test'), default='test')
        sub.add_argument('--output', required=True)
        if command == 'score':
            sub.add_argument('--predictions', required=True)
    sub = commands.add_parser('compare')
    sub.add_argument('reports', nargs='+')
    sub.add_argument('--output', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'validate':
            summaries = []
            for entry in read_json(ROOT / 'catalog.json')['suites']:
                counts = {}
                for split in ('dev', 'test'):
                    identity, rows, _ = load(entry['task'], split, entry['suite'])
                    counts[split] = len(rows)
                summaries.append({**identity, 'counts': counts})
            print(json.dumps(summaries, indent=2))
            return
        if args.command == 'compare':
            result = compare([read_json(path) for path in args.reports])
        else:
            identity, rows, provenance = load(args.task, args.split, args.suite)
            if args.command == 'export':
                result = requests(identity, rows)
            elif args.command == 'baseline':
                result = {**identity, 'predictor': {'name': 'original-order' if args.task == 'ranking' else 'literal'},
                          'predictions': [({'id': r['id'], 'order': list(range(len(r['candidates']))), 'abstained': False}
                                           if args.task == 'ranking' else {'id': r['id'], 'outputs': [r['input']]}) for r in rows]}
            else:
                result = score(identity, rows, provenance, read_json(args.predictions))
        write_new(args.output, result)
        print(json.dumps({'output': args.output, 'task': result.get('task'),
                          'cases': result.get('evaluated_cases')}, indent=2))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    main()
