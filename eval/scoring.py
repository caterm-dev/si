"""Exact-output metrics shared by all predictors; no model dependencies."""

from collections import defaultdict
import hashlib
from pathlib import Path

from .datasets import digest

IDENTITY_KEYS = ('schema_version', 'task', 'suite', 'split', 'dataset_sha256')
KS = (1, 3, 5, 10, 27)


def protocol_hash():
    return hashlib.sha256(''.join(digest(Path(__file__).with_name(name))
                                 for name in ('datasets.py', 'scoring.py')).encode()).hexdigest()


def edit_distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1]


def summarize(rows, ranking):
    if not rows:
        return {'cases': 0}
    count = len(rows)
    families = defaultdict(list)
    for row in rows:
        families[row['family_id']].append(row['correct'])
    result = {
        'cases': count, 'families': len(families),
        'top1_accuracy': sum(r['correct'] for r in rows) / count,
        'top_k_accuracy': {str(k): sum(r['gold_rank'] is not None and r['gold_rank'] <= k for r in rows) / count for k in KS},
        'mrr': sum(1 / r['gold_rank'] if r['gold_rank'] else 0 for r in rows) / count,
        'macro_family_top1': sum(sum(v) / len(v) for v in families.values()) / len(families),
        'abstentions': sum(r['abstained'] for r in rows),
        'baseline_top1_accuracy': sum(r['baseline_correct'] for r in rows) / count,
        'wrong_to_correct': sum(not r['baseline_correct'] and r['correct'] for r in rows),
        'correct_to_wrong': sum(r['baseline_correct'] and not r['correct'] for r in rows),
    }
    if ranking:
        available = sum(r['gold_in_pool'] for r in rows)
        result.update(candidate_recall=available / count,
                      top1_when_gold_available=sum(r['correct'] for r in rows) / available if available else None,
                      empty_pools=sum(r['empty_pool'] for r in rows),
                      policy_failures=sum(not r['policy_pass'] for r in rows))
    else:
        unchanged = [r for r in rows if not r['needs_change']]
        changes = [r for r in rows if r['needs_change']]
        result.update(
            character_error_rate=sum(r['edit_errors'] for r in rows) / sum(r['reference_length'] for r in rows),
            needs_change_cases=len(changes), no_change_cases=len(unchanged),
            correction_accuracy=sum(r['correct'] for r in changes) / len(changes) if changes else None,
            overcorrection_rate=sum(r['changed'] for r in unchanged) / len(unchanged) if unchanged else None,
        )
    return result


def score(identity, rows, provenance, predictions):
    if any(predictions.get(key) != identity[key] for key in IDENTITY_KEYS):
        raise ValueError('Prediction task/suite/split/dataset identity mismatch')
    predictor = predictions.get('predictor')
    if not isinstance(predictor, dict) or not isinstance(predictor.get('name'), str) or not predictor['name'].strip():
        raise ValueError('Predictor must declare a name (and should include revision/config/checkpoint hash)')
    values = predictions.get('predictions')
    if not isinstance(values, list) or any(not isinstance(v, dict) or not isinstance(v.get('id'), str) for v in values):
        raise ValueError('Invalid predictions')
    by_id = {v['id']: v for v in values}
    if len(by_id) != len(values) or set(by_id) != {r['id'] for r in rows}:
        raise ValueError('Predictions must cover every case exactly once; missing/extra/duplicate IDs')
    ranking = identity['task'] == 'ranking'
    results = []
    for row in rows:
        value = by_id[row['id']]
        result = {key: row[key] for key in ('id', 'family_id', 'category', 'track', 'diagnostic')}
        if ranking:
            pool = row['candidates']
            order, abstained = value.get('order'), value.get('abstained')
            if (not isinstance(order, list) or any(type(i) is not int for i in order)
                    or sorted(order) != list(range(len(pool))) or type(abstained) is not bool):
                raise ValueError('Ranking requires a complete index permutation and boolean abstained: ' + row['id'])
            if abstained and order != list(range(len(pool))):
                raise ValueError('Abstention must retain original order: ' + row['id'])
            gold = {i for i, text in enumerate(pool) if text in row['references']}
            rank = next((i + 1 for i, candidate in enumerate(order) if candidate in gold), None)
            policy = (('expected_abstained' not in row or row['expected_abstained'] == abstained)
                      and ('expected_gold_in_pool' not in row or row['expected_gold_in_pool'] == bool(gold))
                      and (not row.get('expected_original_order') or order == list(range(len(pool)))))
            result.update(gold_in_pool=bool(gold), empty_pool=not pool, baseline_correct=0 in gold,
                          policy_pass=policy, abstained=abstained, order=order)
        else:
            outputs = value.get('outputs')
            if (not isinstance(outputs, list) or len(outputs) > 32
                    or not all(isinstance(text, str) and text and len(text.encode('utf-8')) <= 4096 for text in outputs)
                    or len(set(outputs)) != len(outputs)):
                raise ValueError('Generation requires up to 32 distinct nonempty UTF-8 outputs: ' + row['id'])
            rank = next((i + 1 for i, text in enumerate(outputs) if text in row['references']), None)
            top = outputs[0] if outputs else ''
            # Choose the reference with the smallest normalized scalar edit distance.
            reference = min(row['references'], key=lambda ref: (edit_distance(top, ref) / len(ref), ref))
            result.update(baseline_correct=row['input'] in row['references'], abstained=not outputs,
                          needs_change=row['input'] not in row['references'], changed=top != row['input'],
                          edit_errors=edit_distance(top, reference), reference_length=len(reference))
        result.update(correct=rank == 1, gold_rank=rank)
        results.append(result)
    ordinary = [r for r in results if not r['diagnostic']]

    def grouped(records, key):
        return {name: summarize([r for r in records if r[key] == name], ranking)
                for name in sorted({r[key] for r in records})}

    metrics = {'by_track': grouped(ordinary, 'track')}
    metrics['by_category'] = (
        {category: grouped([r for r in ordinary if r['category'] == category], 'track')
         for category in sorted({r['category'] for r in ordinary})}
        if ranking else grouped(ordinary, 'category'))
    if not ranking:
        metrics['overall'] = summarize(ordinary, False)
    else:
        # The original audit covers only one model dataset, not any future large-model corpus.
        audited_id = provenance.get('overlap_dataset_id')
        matches = bool(audited_id and audited_id == predictor.get('training_dataset_id'))
        clean = [r for r, source in zip(results, rows)
                 if matches and not r['diagnostic'] and source.get('overlap', {}).get('status') == 'clear']
        metrics['clean_by_track'] = grouped(clean, 'track')
        metrics['overlap_audit_matches_declared_training_dataset'] = matches
    return {
        **identity, 'kind': 'si-unified-evaluation', 'scorer_sha256': protocol_hash(),
        'predictor': predictor, 'evaluated_cases': len(results), 'partial': False,
        'metrics': metrics, 'diagnostics_by_track': grouped([r for r in results if r['diagnostic']], 'track'),
        'cases': results,
        'note': 'Constructed regression data; labels lack independent review. Derived ranking tracks are correlated. '
                'Keep tasks/tracks separate. Exact text scoring; CER uses Unicode scalars. '
                'No representative production quality or host latency claim. '
                'Training overlap is unknown unless an audit matches the declared training dataset.',
    }


def compare(reports):
    if len(reports) < 2 or any(r.get('kind') != 'si-unified-evaluation' or r.get('partial') is not False for r in reports):
        raise ValueError('Compare at least two full unified reports')
    keys = (*IDENTITY_KEYS, 'scorer_sha256', 'evaluated_cases')
    first = reports[0]
    if any(any(report.get(key) != first.get(key) for key in keys) for report in reports):
        raise ValueError('Reports must use the same task, frozen dataset, split and scoring protocol')
    return {**{key: first[key] for key in keys},
            'models': [{'predictor': r['predictor'], 'metrics': r['metrics'],
                        'diagnostics_by_track': r['diagnostics_by_track']} for r in reports]}
