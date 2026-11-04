"""Source-specific dialogue readers; preserve utterance bytes and provenance."""

from collections import defaultdict
import csv
import gzip
import hashlib
import io
import json
from pathlib import PurePosixPath
import re
import tarfile


def turn(index, speaker, text, **extra):
    return {'id': str(index), 'speaker': str(speaker), 'text': text, **extra}


def conversation(split, origin, identity, method, turns, group=None):
    return {'id': str(identity), 'group': str(group if group is not None else identity),
            'split': split, 'origin': origin, 'method': method, 'turns': turns}


class Archive:
    """Read regular selected members without extracting archive paths to disk."""

    def __init__(self, path):
        self.handle = tarfile.open(path, 'r:*')
        self.members = {}
        for member in self.handle.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('Unsafe corpus archive member')
            if member.isfile():
                if member.name in self.members:
                    raise ValueError('Duplicate corpus archive member')
                self.members[member.name] = member

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.handle.close()

    def matching(self, suffix):
        names = [name for name in self.members if name == suffix or name.endswith('/' + suffix)]
        if len(names) != 1:
            raise ValueError('Expected one archive member: ' + suffix)
        return names[0]

    def read(self, name):
        with self.handle.extractfile(self.members[name]) as handle:
            return handle.read()

    def text(self, suffix):
        return self.read(self.matching(suffix)).decode('utf-8-sig')

    def json(self, name):
        data = self.read(name)
        if name.endswith('.gz'):
            data = gzip.decompress(data)
        return json.loads(data)


class Files(Archive):
    """The same reader interface for individually pinned publisher files."""

    def __init__(self, root, entries):
        self.root = root
        self.members = {entry['path']: None for entry in entries}

    def __exit__(self, *args):
        pass

    def read(self, name):
        if name not in self.members:
            raise ValueError('Unpinned corpus file')
        return (self.root / name).read_bytes()


def convai2(archive, counts):
    for split, filename in [('train', 'train_both_original.txt'),
                            ('validation', 'valid_both_original.txt')]:
        name = archive.matching(filename)
        turns = []
        start = None
        episode = 0
        alternate_view = False
        # Use only original, both-persona files; the other persona views are
        # alternate presentations of these same utterances, not extra dialogues.
        for line_number, line in enumerate(archive.text(filename).splitlines(), 1):
            number, text = line.split(' ', 1)
            if '\t' not in text:
                if turns:
                    if alternate_view:
                        counts['excluded_alternate_speaker_views'] += 1
                    else:
                        yield conversation(split, name + ':' + str(start),
                                           f'{split}:{episode}', 'human-persona-chat', turns)
                    episode += 1
                    turns = []
                counts['excluded_persona_lines'] += 1
                continue
            if start is None or not turns:
                start = line_number
            fields = text.split('\t')
            if len(fields) < 2:
                raise ValueError('Invalid ConvAI2 turn pair')
            if not turns:
                # ConvAI2's second-speaker training view begins with a synthetic
                # silent prompt and repeats a shifted/truncated transcript.
                # Keep the complete first-speaker view, not both presentations.
                alternate_view = fields[0] == '__SILENCE__'
            for speaker, value in enumerate(fields[:2]):
                if value == '__SILENCE__':
                    counts['excluded_silence_placeholders'] += 1
                    continue
                turns.append(turn(f'{line_number}:{speaker}', f'speaker_{speaker + 1}', value))
        if turns:
            if alternate_view:
                counts['excluded_alternate_speaker_views'] += 1
            else:
                yield conversation(split, name + ':' + str(start), f'{split}:{episode}',
                                   'human-persona-chat', turns)


def bst(archive, counts):
    for split, filename in [('train', 'train.json'), ('validation', 'valid.json'), ('test', 'test.json')]:
        name = archive.matching(filename)
        for index, row in enumerate(archive.json(name)):
            # New dialogue only: inherited starters, contexts and model suggestion
            # fields are deliberately not part of the prepared text.
            turns = [turn(i, 'free' if speaker == 0 else 'guided', text)
                     for i, (speaker, text) in enumerate(row['dialog'])]
            counts['excluded_starter_turns'] += 2
            yield conversation(split, name + ':' + str(index), f'{split}:{index}',
                               'human-chat-with-guided-replies', turns)


def topical(archive, counts):
    filenames = {'train': 'train', 'valid_freq': 'validation-frequent',
                 'valid_rare': 'validation-rare', 'test_freq': 'test-frequent', 'test_rare': 'test-rare'}
    for filename, split in filenames.items():
        name = archive.matching('conversations/' + filename + '.json')
        for identity, row in sorted(archive.json(name).items()):
            turns = [turn(i, item['agent'], item['message']) for i, item in enumerate(row['content'])]
            yield conversation(split, name + ':' + identity, identity,
                               'human-knowledge-grounded-chat', turns)


def taskmaster(archive, counts):
    split_by_id = {}
    tm3_splits = defaultdict(set)
    for filename, split in [('train.csv', 'train'), ('dev.csv', 'validation'), ('test.csv', 'test')]:
        name = archive.matching('TM-1-2019/train-dev-test/' + filename)
        for row in csv.reader(io.StringIO(archive.read(name).decode())):
            if row and row[0].startswith('dlg-'):
                if row[0] in split_by_id:
                    raise ValueError('Taskmaster dialogue crosses splits')
                split_by_id[row[0]] = split
    seen_records = set()
    for name in sorted(archive.members):
        match = re.search(r'/TM-3-2020/splits/(train|dev|test)/[^/]+\.tsv$', name)
        if not match:
            continue
        split = {'train': 'train', 'dev': 'validation', 'test': 'test'}[match[1]]
        # The final TSV column is the original dialogue ID; the preceding
        # columns are model examples, not additional corpus conversations.
        for line in archive.read(name).decode('utf-8').splitlines():
            identity = line.rsplit('\t', 1)[-1].strip()
            if not identity.startswith('dlg-'):
                raise ValueError('Invalid Taskmaster-3 split identity')
            tm3_splits[identity].add(split)
    for name in sorted(archive.members):
        if name.endswith('TM-1-2019/self-dialogs.json'):
            method, version = 'human-written-self-dialogue', 'tm1'
        elif name.endswith('TM-1-2019/woz-dialogs.json'):
            method, version = 'human-spoken-woz', 'tm1'
        elif re.search(r'/TM-2-2020/data/[^/]+\.json$', name):
            method, version = 'human-spoken-woz', 'tm2'
        elif re.search(r'/TM-3-2020/data/[^/]+\.json$', name):
            method, version = 'human-written-self-dialogue', 'tm3'
        else:
            continue
        for row_index, row in enumerate(archive.json(name)):
            identity = row.get('conversation_id', row.get('conversationId'))
            if not identity:
                raise ValueError('Missing Taskmaster conversation ID')
            assignments = split_by_id if version == 'tm1' and method == 'human-written-self-dialogue' else {}
            split = assignments.get(identity, 'unsplit')
            turns = []
            for item in row['utterances']:
                speaker = item['speaker']
                if not speaker:
                    speaker = 'unknown'
                    counts['unknown_speaker_turns'] += 1
                turns.append(turn(item['index'], speaker, item['text']))
            counts[version + '_conversations'] += 1
            group = version + ':' + identity
            fingerprint = hashlib.sha256(json.dumps(
                [group, method, split, turns], ensure_ascii=False,
                sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            if fingerprint in seen_records:
                counts['excluded_exact_duplicate_records'] += 1
                continue
            seen_records.add(fingerprint)
            # A few upstream dialogue IDs are reused for different transcripts.
            # Keep every distinct record and its original grouping identity.
            record_id = group + ':' + PurePosixPath(name).name + ':' + str(row_index)
            record = conversation(split, name + ':' + identity + ':' + str(row_index),
                                  record_id, method, turns, group=group)
            if version == 'tm3':
                # The official TSV splits are per model example and overlap at
                # dialogue level. Preserve their membership as evidence; do not
                # mislabel the complete original dialogue as clean training data.
                record['upstream_example_splits'] = sorted(tm3_splits[identity])
                if len(tm3_splits[identity]) > 1:
                    counts['tm3_upstream_examples_cross_splits'] += 1
                elif not tm3_splits[identity]:
                    counts['tm3_without_upstream_examples'] += 1
            yield record


def abcd(archive, counts):
    name = archive.matching('data/abcd_v1.1.json.gz')
    for original_split, rows in archive.json(name).items():
        split = {'train': 'train', 'dev': 'validation', 'test': 'test'}[original_split]
        for row in rows:
            turns = []
            for i, item in enumerate(row['original']):
                speaker, text = item
                if speaker not in ('agent', 'customer'):
                    counts['excluded_action_records'] += 1
                    continue
                turns.append(turn(i, speaker, text))
            identity = str(row['convo_id'])
            yield conversation(split, name + ':' + identity, identity,
                               'human-service-chat', turns)


def sgd(archive, counts):
    for name in sorted(archive.members):
        match = re.search(r'/(train|dev|test)/dialogues_\d+\.json$', name)
        if not match:
            continue
        split = {'train': 'train', 'dev': 'validation', 'test': 'test'}[match[1]]
        for row in archive.json(name):
            identity = row['dialogue_id']
            turns = [turn(i, item['speaker'], item['utterance']) for i, item in enumerate(row['turns'])]
            # SGD numbers dialogue IDs independently within each split.
            yield conversation(split, name + ':' + identity, split + ':' + identity,
                               'simulator-plan-human-paraphrase', turns)


def eligible_oasst(row):
    if row['lang'] != 'en':
        return 'non_english'
    if row['deleted'] or row['synthetic'] or row['review_result'] is not True:
        return 'unreviewed_deleted_or_synthetic'
    if not row.get('labels'):
        return 'low_or_missing_quality'
    labels = dict(zip(row['labels']['name'], row['labels']['value']))
    if any(labels.get(key, 0) > 0 for key in ('spam', 'pii', 'lang_mismatch', 'not_appropriate')):
        return 'flagged_content'
    if labels.get('quality', 0) < 0.5:
        return 'low_or_missing_quality'
    return None


def oasst(source, raw_root, counts):
    # Optional dependency, used only for this publisher's official split files.
    import pyarrow.parquet as parquet
    for entry in source['files']:
        if not entry['path'].endswith('.parquet'):
            continue
        split = 'validation' if '/validation-' in entry['path'] else 'train'
        trees = defaultdict(list)
        for batch in parquet.ParquetFile(raw_root / entry['path']).iter_batches(batch_size=1024):
            for row in batch.to_pylist():
                reason = eligible_oasst(row)
                if reason:
                    counts['excluded_' + reason] += 1
                    continue
                trees[row['message_tree_id']].append(turn(
                    row['message_id'], row['role'], row['text'], parent=row['parent_id']))
        for identity, turns in sorted(trees.items()):
            # A tree is a graph, not a linear transcript. Retain original parent
            # edges even when a parent was filtered; never join sibling replies.
            yield conversation(split, entry['path'] + ':' + identity, identity,
                               'human-assistant-tree', sorted(turns, key=lambda t: t['id']))


def raw_conversations(source, raw_root, counts):
    if source['reader'] == 'oasst1':
        yield from oasst(source, raw_root, counts)
        return
    readers = {'convai2': convai2, 'bst': bst, 'topical-chat': topical,
               'taskmaster': taskmaster, 'abcd': abcd, 'sgd': sgd}
    context = (Files(raw_root, source['files']) if source.get('individual_files')
               else Archive(raw_root / source['files'][0]['path']))
    with context as archive:
        yield from readers[source['reader']](archive, counts)


def conversations(source, raw_root, counts):
    for record in raw_conversations(source, raw_root, counts):
        retained = []
        for item in record['turns']:
            if not isinstance(item['text'], str):
                raise ValueError('Nontext dialogue utterance')
            if not item['text'].strip():
                counts['excluded_empty_turns'] += 1
            elif any(ord(c) < 32 and c not in '\n\r\t' for c in item['text']):
                counts['excluded_control_turns'] += 1
            else:
                retained.append(item)
        if not retained:
            counts['excluded_empty_conversations'] += 1
            continue
        record['turns'] = retained
        yield record
