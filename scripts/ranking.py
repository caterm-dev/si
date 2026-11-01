#!/usr/bin/env python3
"""Maintain ranking attribution and synthetic calibration without the retired frequency import."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Data/Ranking/wordfreq-3.1.1'


def notices():
    records = json.loads((ROOT / 'Data/Vocabulary/meta.json').read_text())['upstreams']
    manifest = next(record['metadata'] for record in records if record['id'] == 'english-frequency-bootstrap')
    documents = [('README.md', manifest['documentation_sha256']),
                 ('LICENSE.txt', manifest['code_notice_sha256'])]
    documents += [(name, entry['sha256']) for name, entry in manifest['license_files'].items()]
    output = (SOURCE / 'PORT-NOTICE.txt').read_text()
    for name, checksum in documents:
        data = (SOURCE / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise ValueError('Notice/license checksum mismatch: ' + name)
        output += data.decode() + '\n\n'
    return output


def calibration():
    source = json.loads((ROOT / 'Data/Ranking/calibration.json').read_text())
    switches = stays = 0
    for example in source['examples']:
        runs = example['languages']
        if len(runs) != len(example['tokens']) or set(runs) - set('CE'):
            raise ValueError('Invalid calibration language sequence')
        for a, b in zip(runs, runs[1:]):
            switches += a != b
            stays += a == b
    probability = (switches + 1) / (switches + stays + 2)
    return ('// Generated from Data/Ranking/calibration.json by scripts/ranking.py.\n'
            '// Authored synthetic development set; add-one estimate, not population typing statistics.\n'
            'enum RankingCalibration {\n'
            f'    static let switchProbability = {probability!r}\n'
            '}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    outputs = {ROOT / 'mac/SI/Core/RankingCalibration.swift': calibration(),
               ROOT / 'mac/SI/Resources/RankingNotices.txt': notices()}
    for output, source in outputs.items():
        if args.check:
            if output.read_text() != source:
                raise SystemExit(f'{output.name} is stale; run python3 scripts/ranking.py')
        else:
            output.write_text(source)
    print('Ranking data and source checksums verified' if args.check else 'Generated ranking data')


if __name__ == '__main__':
    main()
