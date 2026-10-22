#!/usr/bin/env python3
"""Maintain ranking attribution/calibration and import initial wordfreq weights offline."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Data/Ranking/wordfreq-3.1.1'


def unpack(data):
    """Read only the bounded msgpack types used by cBpack, without executing package code."""
    position = 0

    def read(size):
        nonlocal position
        if size < 0 or position + size > len(data):
            raise ValueError('Truncated cBpack')
        value = data[position:position + size]
        position += size
        return value

    def number(size):
        return int.from_bytes(read(size), 'big')

    def value(depth=0):
        if depth > 4:
            raise ValueError('Unexpected cBpack nesting')
        tag = number(1)
        if tag < 128:
            return tag
        if tag & 0xe0 == 0xa0:
            return read(tag & 31).decode('utf-8')
        if tag in (0xd9, 0xda, 0xdb):
            return read(number({0xd9: 1, 0xda: 2, 0xdb: 4}[tag])).decode('utf-8')
        if tag & 0xf0 == 0x90 or tag in (0xdc, 0xdd):
            count = tag & 15 if tag < 0xa0 else number(2 if tag == 0xdc else 4)
            if count > 1_000_000:
                raise ValueError('Oversized cBpack array')
            return [value(depth + 1) for _ in range(count)]
        if tag & 0xf0 == 0x80:
            return {value(depth + 1): value(depth + 1) for _ in range(tag & 15)}
        if tag in (0xcc, 0xcd, 0xce):
            return number({0xcc: 1, 0xcd: 2, 0xce: 4}[tag])
        raise ValueError(f'Unsupported cBpack tag {tag}')

    result = value()
    if position != len(data) or result[0] != {'format': 'cB', 'version': 1}:
        raise ValueError('Invalid cBpack envelope')
    return result[1:]


def frequency_bins(words):
    """Maintenance-only initial frequency import; runtime dictionaries contain integer weights."""
    manifest = json.loads((SOURCE / 'source.json').read_text())
    raw = (SOURCE / 'large_en.msgpack.gz').read_bytes()
    if hashlib.sha256(raw).hexdigest() != manifest['data_sha256']:
        raise ValueError('Source checksum mismatch')
    expanded = gzip.decompress(raw)
    if len(expanded) > 32 * 1024 * 1024:
        raise ValueError('Oversized cBpack')
    buckets = unpack(expanded)
    lookup = {word: index for index, bucket in enumerate(buckets) for word in bucket}
    # The source's large-list minimum is 10^-8; missing terms back off one decade below it.
    return [lookup.get(word.lower(), 900) for word in words]


def notices():
    manifest = json.loads((SOURCE / 'source.json').read_text())
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
