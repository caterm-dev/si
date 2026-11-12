#!/usr/bin/env python3
"""Split Chinese words and keep single-character entries SI can display on this Mac."""

import argparse
import csv
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unicodedata

from csv_dictionary import COLUMNS, DATA, ROOT, integer


def single_character_rows(source):
    reader = csv.reader(source, strict=True)
    if next(reader, None) != COLUMNS:
        raise ValueError('Expected text,reading,weight header')

    known = set()
    existing = []
    words = []
    for row in reader:
        if len(row) != len(COLUMNS) or not all(row):
            raise ValueError(f'Line {reader.line_num}: expected three nonempty fields')
        text, reading, weight = row
        if len(text) == 1:
            known.add(text)
            existing.append(row)
        else:
            words.append((reader.line_num, text, reading, weight))

    additions = []
    for line, text, reading, weight in words:
        # Punctuation and spaces do not consume a Pinyin syllable.
        characters = [char for char in text if not unicodedata.category(char).startswith(('P', 'Z'))]
        syllables = reading.split("'")
        if len(characters) != len(syllables):
            raise ValueError(f'Line {line}: cannot align characters with Pinyin syllables')
        for char, syllable in zip(characters, syllables):
            if char in known:
                continue
            if (not syllable.isascii() or not syllable.isalpha() or not syllable.islower()
                    or syllable[0] not in 'abcdefghjklmnopqrstwxyz'):
                raise ValueError(f'Line {line}: invalid single-character reading')
            integer(weight, 0, f'count on line {line}')
            additions.append((char, syllable, weight))
            known.add(char)
    return existing, additions


def displayable_characters(rows):
    characters = list(dict.fromkeys(row[0] for row in rows))
    if not characters:
        return set()

    support = ROOT / 'mac/SI/InputMethod/CandidateTextSupport.swift'
    with tempfile.TemporaryDirectory(prefix='si-glyph-check-') as directory:
        probe = Path(directory) / 'check.swift'
        probe.write_text(support.read_text(encoding='utf-8') + '''
import Foundation

let characters = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
var support = CandidateTextSupport()
let displayable = characters.filter { support.canDisplay($0) }
FileHandle.standardOutput.write(try JSONEncoder().encode(displayable))
''', encoding='utf-8')
        result = subprocess.run(
            ['xcrun', 'swift', '-module-cache-path', str(Path(directory) / 'modules'), str(probe)],
            input=json.dumps(characters, ensure_ascii=False), encoding='utf-8', capture_output=True,
        )
        if result.returncode:
            raise ValueError(f'Could not check macOS font coverage:\n{result.stderr.strip()}')
        return set(json.loads(result.stdout))


def write_result(output, rows):
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=output.parent, prefix='.character-entries-')
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='') as handle:
            writer = csv.writer(handle, lineterminator='\n')
            writer.writerow(COLUMNS)
            writer.writerows(rows)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog='Requires macOS and the Swift toolchain.')
    parser.add_argument('csv', nargs='?', type=Path, default=DATA / 'Chinese/base.csv',
                        help='Source CSV (default: Data/Chinese/base.csv)')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/base-with-characters.csv',
                        help='Result CSV (default: .build/base-with-characters.csv)')
    parser.add_argument('--dry-run', action='store_true', help='Count output entries without writing')
    args = parser.parse_args()
    try:
        path = args.csv.resolve(strict=True)
        output = args.output.absolute()
        if output.resolve() == path:
            raise ValueError('Output CSV must differ from the source CSV')
        with path.open(encoding='utf-8-sig', newline='') as source:
            existing, additions = single_character_rows(source)
        all_rows = existing + additions
        displayable = displayable_characters(all_rows)
        rows = [row for row in all_rows if row[0] in displayable]
        new_count = sum(row[0] in displayable for row in additions)
        removed_count = len(all_rows) - len(rows)
        if not args.dry_run:
            write_result(output, rows)
    except (OSError, ValueError, csv.Error) as error:
        parser.exit(1, f'Chinese character entries error: {error}\n')
    action = 'Would write' if args.dry_run else 'Wrote'
    print(f'{action} {len(rows):,} single-character entries to {output} '
          f'({new_count:,} new, {removed_count:,} removed for missing glyphs)')


if __name__ == '__main__':
    main()
