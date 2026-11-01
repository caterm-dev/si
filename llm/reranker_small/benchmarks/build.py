"""Reproduce a versioned authored challenge plus real SICore candidate snapshots."""

import argparse
from collections import Counter, deque
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import unicodedata

from corpus.common import new_directory
from llm.pinyin_to_text.common import normalized
from ..settings import REPO, file_hash, fingerprint, read_json, write_json

HERE = Path(__file__).resolve().parent
REVISION = 'chinese-v1'
NEUTRAL = ('桌上放着一本空白笔记，窗边透进柔和的光线。大家整理好材料，安静地坐在各自的位置上。'
           '走廊里没有其他声音，纸张按顺序放在文件夹中。接下来，我们把注意力转回正在讨论的问题。\n\n') * 5


def audit_normalized(text):
    return ' '.join(normalized(text).split())


def spelling(value):
    return re.sub(r"[\s']", '', value.lower().replace('u:', 'v').replace('ü', 'v'))


def group_for(value):
    # Aliases, repeated homophone families and sentence templates stay together.
    return 'spelling:' + spelling(value)


def split_for(group):
    return 'dev' if int(hashlib.sha256(('si-challenge-v1:' + group).encode()).hexdigest()[:8], 16) % 5 == 0 else 'test'


def assign_families(rows):
    parents = {}

    def find(key):
        parents.setdefault(key, key)
        if parents[key] != key:
            parents[key] = find(parents[key])
        return parents[key]

    for row in rows:
        key = group_for(row['input'])
        find(key)
        pool = row['candidates']
        for i, left in enumerate(pool):
            for right in pool[i + 1:]:
                # Shared wrappers must not put the same lexical contrast into both splits.
                start = 0
                while start < min(len(left), len(right)) and left[start] == right[start]:
                    start += 1
                a, b = left[start:], right[start:]
                while a and b and a[-1] == b[-1]:
                    a, b = a[:-1], b[:-1]
                if a and b:
                    contrast = 'contrast:' + json.dumps(sorted((a, b)), ensure_ascii=False)
                    parents[find(contrast)] = find(key)
    components = {}
    for row in rows:
        key = group_for(row['input'])
        components.setdefault(find(key), set()).add(key)
    names = {key: min(values) for key, values in components.items()}
    for row in rows:
        row['family_id'] = names[find(group_for(row['input']))]
        row['split'] = split_for(row['family_id'])


def anchors():
    result = []
    with (HERE / 'lexical.tsv').open() as handle:
        for family in csv.DictReader(handle, delimiter='\t'):
            pool = [family['candidate_a'], family['candidate_b']]
            if pool[0] == pool[1]:
                raise ValueError('Duplicate authored alternatives: ' + family['id'])
            for side in ('a', 'b'):
                result.append({'id': family['id'] + '-' + side, 'category': family['category'],
                               'input': family['input'], 'context': family['context_' + side],
                               'candidates': pool, 'references': [family['candidate_' + side]],
                               'tags': ['context-contrast'], 'source': 'lexical.tsv'})
    for line in (HERE / 'additional.jsonl').read_text().splitlines():
        value = json.loads(line)
        value['input'] = value['input'].replace(' ', '')
        value.update(source='additional.jsonl')
        result.append(value)
    assign_families(result)
    if len({row['id'] for row in result}) != len(result):
        raise ValueError('Repeated anchor ID')
    return result


def check_readings(rows, database):
    """Use maintained readings, not an unrelated automatic sentence transliterator."""
    characters = {}
    words = {}
    targets = sorted({word for row in rows for word in row['candidates']})
    with sqlite3.connect(f'file:{Path(database).resolve()}?mode=ro', uri=True) as connection:
        tables = [name for name, in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
                  if re.fullmatch(r'tbl_[1-7]_[a-z]', name)]
        for table in tables:
            for key, word in connection.execute(f'SELECT key,value FROM {table} WHERE length(value)=1'):
                characters.setdefault(word, set()).add(spelling(key))
            placeholders = ','.join('?' for _ in targets)
            for key, word in connection.execute(f'SELECT key,value FROM {table} WHERE value IN ({placeholders})', targets):
                words.setdefault(word, set()).add(spelling(key))

    def compatible(text, raw):
        raw = spelling(raw)
        if text in words and all('\u3400' <= c <= '\u9fff' for c in text):
            return raw in words[text]
        states = {0}
        for character in text:
            options = characters.get(character, {spelling(character)})
            states = {offset + len(option) for offset in states for option in options
                      if raw.startswith(option, offset)}
        return len(raw) in states

    errors = [(row['id'], text, row['input']) for row in rows for text in row['candidates']
              if not compatible(text, row['input'])]
    if errors:
        raise ValueError('Incompatible authored Pinyin/candidate readings: ' + json.dumps(errors, ensure_ascii=False))
    return {'anchors': len(rows), 'candidate_checks': sum(len(row['candidates']) for row in rows),
            'database_sha256': file_hash(database),
            'method': 'Known whole-word readings; otherwise character-reading alignment with exact ASCII spans. '
                      'Tone-free alignment does not independently verify semantic labels.'}


class Matcher:
    """Streaming Aho-Corasick matching; never concatenate unrelated documents."""

    def __init__(self, patterns):
        self.next, self.fail, self.out = [{}], [0], [set()]
        for pattern, identities in patterns.items():
            state = 0
            for character in pattern:
                if character not in self.next[state]:
                    self.next[state][character] = len(self.next)
                    self.next.append({})
                    self.fail.append(0)
                    self.out.append(set())
                state = self.next[state][character]
            self.out[state].update(identities)
        queue = deque(self.next[0].values())
        while queue:
            state = queue.popleft()
            for character, target in self.next[state].items():
                queue.append(target)
                fallback = self.fail[state]
                while fallback and character not in self.next[fallback]:
                    fallback = self.fail[fallback]
                self.fail[target] = self.next[fallback].get(character, 0)
                self.out[target].update(self.out[self.fail[target]])

    def search(self, text):
        state, found = 0, set()
        for character in text:
            while state and character not in self.next[state]:
                state = self.fail[state]
            state = self.next[state].get(character, 0)
            found.update(self.out[state])
        return found


def audit_overlap(rows, data_path):
    patterns = {}
    eligible = set()
    for row in rows:
        for text in row['references']:
            pattern = audit_normalized(row['context'] + text)
            if len(pattern) >= 8:
                patterns.setdefault(pattern, set()).add(row['id'])
                eligible.add(row['id'])
    matcher = Matcher(patterns)
    matches = {row['id']: [] for row in rows}
    audit = {'method': 'NFKC/casefold/whitespace-normalized context+reference substring, minimum 8 characters; '
                       'not a semantic/paraphrase or whole-Web independence check.', 'splits': {}}
    if data_path is None:
        return {row['id']: {'status': 'not-audited', 'matched_splits': []} for row in rows}, audit
    data_path = Path(data_path)
    manifest = read_json(data_path / 'manifest.json')
    if fingerprint({key: value for key, value in manifest.items() if key != 'dataset_id'}) != manifest['dataset_id']:
        raise ValueError('Invalid overlap-audit dataset identity')
    audit['dataset_id'] = manifest['dataset_id']
    for split in ('train', 'validation', 'test'):
        name = split + '.documents.jsonl'
        hasher = hashlib.sha256()
        count = 0
        hits = set()
        with (data_path / name).open('rb') as handle:
            for line in handle:
                hasher.update(line)
                count += 1
                hits.update(matcher.search(audit_normalized(json.loads(line)['text'])))
                if count % 250000 == 0:
                    print(json.dumps({'event': 'overlap-audit', 'split': split, 'documents': count}), flush=True)
        if hasher.hexdigest() != manifest['files'][name]:
            raise ValueError('Modified overlap-audit document file: ' + name)
        for identity in hits:
            matches[identity].append(split)
        audit['splits'][split] = {'documents': count, 'sha256': hasher.hexdigest(), 'matched_anchors': sorted(hits)}
    return {row['id']: {'status': 'match' if matches[row['id']] else 'clear' if row['id'] in eligible else 'too-short',
                       'matched_splits': matches[row['id']]} for row in rows}, audit


def ordered(pool, identity):
    # Synthetic order is a counterbalanced fixture, never an engine baseline.
    start = int(hashlib.sha256(identity.encode()).hexdigest()[:8], 16) % len(pool)
    return pool[start:] + pool[:start]


def make_cases(rows, snapshots, overlaps):
    result = []
    for row in rows:
        shared = {key: row[key] for key in ('category', 'input', 'family_id', 'split')}
        shared.update(anchor_id=row['id'], tags=row.get('tags', []), overlap=overlaps[row['id']], diagnostic=False)
        pool = ordered(row['candidates'], row['id'])
        result.append({**shared, 'id': row['id'] + '/controlled', 'track': 'controlled',
                       'context': row['context'], 'candidates': pool, 'references': row['references'],
                       'candidate_origin': 'SI-authored tone-free aligned contrast; synthetic pool order'})
        if row['source'] == 'lexical.tsv':
            result.append({**shared, 'id': row['id'] + '/long-context', 'track': 'long_context',
                           'context': NEUTRAL + row['context'], 'candidates': pool, 'references': row['references'],
                           'candidate_origin': 'Authored contrast; neutral long prefix, recent disambiguating clause'})
            result.append({**shared, 'id': row['id'] + '/phrase', 'track': 'phrase', 'input': None,
                           'context': '', 'candidates': [row['context'] + text for text in pool],
                           'references': [row['context'] + text for text in row['references']],
                           'candidate_origin': 'Constructed phrase contrast; text-only, no sentence-Pinyin claim'})
        snapshot = snapshots[row['input']]
        result.append({**shared, 'id': row['id'] + '/decoder', 'track': 'decoder',
                       'context': row['context'], 'candidates': [v['text'] for v in snapshot['candidates']],
                       'references': row['references'], 'candidate_details': snapshot['candidates'],
                       'decoder': {key: snapshot[key] for key in ('totalEligible', 'excludedPartialOrCompletion', 'literalAvailable')},
                       'candidate_origin': 'Actual SICore full-candidate order, no gold injection'})
        if row['category'] == 'umlaut':
            for name, value in [('unicode', row['input'].replace('v', 'ü')), ('colon', row['input'].replace('v', 'u:'))]:
                snapshot = snapshots[value]
                result.append({**shared, 'id': row['id'] + '/alias-' + name, 'track': 'decoder_alias',
                               'input': value, 'context': row['context'],
                               'candidates': [v['text'] for v in snapshot['candidates']], 'references': row['references'],
                               'candidate_details': snapshot['candidates'],
                               'decoder': {key: snapshot[key] for key in ('totalEligible', 'excludedPartialOrCompletion', 'literalAvailable')},
                               'candidate_origin': 'Actual SICore alias query, no gold injection'})
        if int(hashlib.sha256(row['id'].encode()).hexdigest()[:8], 16) % 10 == 0:
            wrong = [text for text in pool if text not in row['references']]
            if wrong:
                result.append({**shared, 'id': row['id'] + '/missing-gold', 'track': 'missing_gold',
                               'diagnostic': True, 'context': row['context'], 'candidates': wrong,
                               'references': row['references'], 'expected_gold_in_pool': False,
                               'candidate_origin': 'Controlled recall failure, deliberately removed gold'})
    return result


def diagnostics():
    values = [
        ('canonical-unicode', 'Unicode text should remain byte-exact: ', ['café', 'cafe\u0301'], ['café', 'cafe\u0301']),
        ('emoji', '发送表示正在编程的表情：', ['👩🏽‍💻', '👨‍💻'], ['👩🏽‍💻', '👨‍💻']),
        ('rare-han', '请原样保留这个生僻汉字：', ['𠮷', '吉'], ['𠮷']),
        ('traditional', '引用原文时保留原有字形：', ['軟體', '软件'], ['軟體', '软件']),
        ('punctuation', '这里需要表达感谢：', ['谢谢！', '谢谢!'], ['谢谢！', '谢谢!']),
        ('identifier-case', '变量名必须逐字保留：', ['parseHTTPResponse', 'parseHttpResponse'], ['parseHTTPResponse']),
        ('url', '项目主页地址为：', ['https://example.org/文档', 'https://example.org/文當'], ['https://example.org/文档']),
        ('apostrophe', '这个字符串包含英文单引号：', ["don't", 'dont'], ["don't"]),
        ('equal-bytes', '这个词是', ['测试', '测试'], ['测试']),
        ('no-context', '', ['时间', '实践', '事件', '世间'], ['时间', '实践', '事件', '世间']),
        ('paragraph-context', '先整理资料。\n\n接下来要编写一份书面', ['报告', '包裹'], ['报告']),
        ('pool-32', '从以下标号中选择第十七项：', [f'候选项{i:02d}' for i in range(1, 33)], ['候选项17']),
        ('overlong-first', '', ['测试' * 150, '测试'], ['测试' * 150]),
        ('overlong-last', NEUTRAL, ['测试', '测试' * 150], ['测试']),
        ('byte-fallback-context', '🧪' * 200 + '临床', ['试验', '誓言'], ['试验']),
    ]
    for identity, context, pool, references in values:
        yield {'id': 'diagnostic/' + identity, 'anchor_id': 'diagnostic/' + identity,
               'family_id': 'diagnostic/' + identity, 'split': 'test', 'category': 'robustness',
               'track': 'robustness', 'diagnostic': True, 'context': context, 'input': None,
               'candidates': pool, 'references': references, 'tags': [identity],
               'overlap': {'status': 'not-audited', 'matched_splits': []},
               'expected_abstained': identity.startswith('overlong'),
               'expected_original_order': identity in ('equal-bytes', 'overlong-first', 'overlong-last'),
               'candidate_origin': 'Authored robustness diagnostic, not production ranking accuracy'}


def validate(cases):
    identities, assignments = set(), {}
    for row in cases:
        if row['id'] in identities or row['split'] not in ('dev', 'test'):
            raise ValueError('Repeated case ID or invalid split')
        identities.add(row['id'])
        group = row['family_id']
        if group in assignments and assignments[group] != row['split']:
            raise ValueError('Family crosses dev/test')
        assignments[group] = row['split']
        if (not isinstance(row['context'], str) or not isinstance(row['candidates'], list)
                or len(row['candidates']) > 32 or not row['references']):
            raise ValueError('Invalid case shape: ' + row['id'])
        for text in row['candidates'] + row['references']:
            if not text or len(text.encode()) > 4096 or any(unicodedata.category(c) in ('Cc', 'Cs') for c in text):
                raise ValueError('Invalid candidate text: ' + row['id'])
        if not row['candidates'] and not row['track'].startswith('decoder'):
            raise ValueError('Empty authored candidate pool')
        if row['track'].startswith('decoder'):
            details = row['candidate_details']
            if [v['text'] for v in details] != row['candidates'] or len({v['identity'] for v in details}) != len(details):
                raise ValueError('Decoder identity/text mismatch')
            if not row['decoder']['literalAvailable']:
                raise ValueError('Decoder failed exact-literal preservation')
    signatures = [(r['track'], r['context'], tuple(r['candidates']), tuple(r['references']), r.get('input')) for r in cases]
    if len(signatures) != len(set(signatures)):
        raise ValueError('Repeated query/pool/reference/input case')
    return {'cases': len(cases), 'anchors': len({r['anchor_id'] for r in cases if not r['diagnostic']}),
            'families': len({r['family_id'] for r in cases if not r['diagnostic']}),
            'splits': dict(Counter(r['split'] for r in cases)), 'tracks': dict(Counter(r['track'] for r in cases)),
            'categories': dict(Counter(r['category'] for r in cases)),
            'gold_positions_controlled': dict(Counter(str(next(i for i, v in enumerate(r['candidates']) if v in r['references']))
                                                      for r in cases if r['track'] == 'controlled')),
            'empty_decoder_pools': sum(not r['candidates'] for r in cases),
            'overlap_statuses': dict(Counter(r['overlap']['status'] for r in cases if not r['diagnostic']))}


def write_jsonl(path, values):
    with Path(path).open('w') as handle:
        for value in values:
            handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n')


def build(output, exporter, data_path=None):
    rows = anchors()
    readings = check_readings(rows, REPO / 'mac/SI/Core/Resources/Chinese/si-pinyin.sqlite')
    overlaps, audit = audit_overlap(rows, data_path)
    inputs = {row['input'] for row in rows}
    for row in rows:
        if row['category'] == 'umlaut':
            inputs.update((row['input'].replace('v', 'ü'), row['input'].replace('v', 'u:')))
    requests = [{'id': str(i), 'input': text} for i, text in enumerate(sorted(inputs))]
    raw = ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in requests)
    process = subprocess.run([str(Path(exporter).resolve())], input=raw, text=True, capture_output=True, check=True)
    snapshots = [json.loads(line) for line in process.stdout.splitlines()]
    if [(r['id'], r['input']) for r in snapshots] != [(r['id'], r['input']) for r in requests]:
        raise ValueError('Exporter response/request mismatch')
    cases = make_cases(rows, {row['input']: row for row in snapshots}, overlaps) + list(diagnostics())
    coverage = validate(cases)
    resources = {str(p.relative_to(REPO)): file_hash(p) for p in sorted((REPO / 'mac/SI/Core/Resources').rglob('*')) if p.is_file()}
    code = {str(p.relative_to(REPO)): file_hash(p) for p in sorted((REPO / 'mac/SI/Core').glob('*.swift'))}
    code['Tools/SICandidateExport/SICandidateExport.swift'] = file_hash(REPO / 'Tools/SICandidateExport/SICandidateExport.swift')
    with new_directory(output) as staged:
        for split in ('dev', 'test'):
            write_jsonl(staged / (split + '.jsonl'), [row for row in cases if row['split'] == split])
        write_jsonl(staged / 'decoder-snapshots.jsonl', snapshots)
        write_json(staged / 'overlap-audit.json', audit)
        write_json(staged / 'coverage.json', coverage)
        write_json(staged / 'provenance.json', {
            'schema_version': 1, 'revision': REVISION,
            'origin': 'SI-authored AI-assisted challenge contexts/labels; decoder pools exported from existing SICore. '
                      'No private typing or external test corpus used. Not independently human-annotated.',
            'license': 'Authored contexts/labels: GPL-3.0-only; decoder text retains existing source attribution, '
                       'including Wanxiang CC-BY-4.0. See NOTICE.md and licenses/.',
            'candidate_policy': 'Both enabled languages, no learning or personal phrases, fixed time; '
                                'first 32 whole nonliteral/noncompletion candidates in engine order. '
                                'Language-aware IDs retained; gold never injected into decoder pools.',
            'split_policy': 'Seeded hash of connected normalized-input/lexical-contrast families, including umlaut aliases. '
                            'Shared sentence wrappers cannot split the same contrast across dev/test.',
            'limitations': 'Constructed domain/word coverage is not a representative user distribution; related variants '
                           'are correlated. Tone-free spelling checks are not semantic annotation review. '
                           'Overlap audit excludes exact matching anchors from clean metrics, not paraphrases. '
                           'Prefix/whole score calibration, personal learning, literal choice and host events are not tested.',
            'readings': readings, 'resources': resources, 'core_code': code,
            'builder_sources': {p.name: file_hash(p) for p in (HERE / 'lexical.tsv', HERE / 'additional.jsonl', HERE / 'build.py')},
            'overlap_dataset_id': audit.get('dataset_id'),
        })
        (staged / 'licenses').mkdir()
        for source, name in [('LICENSE', 'SI-GPL-3.0.txt'),
                             ('Data/Vocabulary/Wanxiang/LICENSE', 'Wanxiang-CC-BY-4.0.txt'),
                             ('Data/Vocabulary/Wanxiang/LICENSE-SCOPE.md', 'Wanxiang-LICENSE-SCOPE.md'),
                             ('Data/Vocabulary/Wanxiang/NOTICE.md', 'Wanxiang-NOTICE.md')]:
            shutil.copy2(REPO / source, staged / 'licenses' / name)
        (staged / 'NOTICE.md').write_text(
            '# Chinese candidate challenge attribution\n\n'
            'Contexts, labels and challenge construction are SI-authored with AI assistance under GPL-3.0-only. '
            'No independent human annotation or production accuracy claim is made.\n\n'
            'Native candidate text is produced by the existing SI dictionaries; Wanxiang data originates from '
            'https://github.com/amzxyz/rime-wanxiang-data at revision adfa047c339627737f0a4c75674a8042c1ef7f72 '
            'and retains CC BY 4.0. Retained license/scope/notices are in licenses/. '
            'The SI-maintained English/Chinese resources and their existing attribution are documented in '
            'Data/Vocabulary/meta.json, Data/English/licenses/, Data/Ranking/ and Data/Chinese/MSIME/. '
            'Resource hashes and source changes (candidate export/filtering and authored contexts) are recorded '
            'in provenance.json. No upstream program source was copied.\n')
        write_json(staged / 'manifest.json', {
            'schema_version': 1, 'revision': REVISION, 'coverage': coverage,
            'files': {str(p.relative_to(staged)): file_hash(p) for p in sorted(staged.rglob('*')) if p.is_file()},
        })
    return coverage


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--exporter', type=Path, required=True)
    parser.add_argument('--audit-data', type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.output, args.exporter, args.audit_data), indent=2))
