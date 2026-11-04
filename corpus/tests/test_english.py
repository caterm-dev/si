"""Synthetic dialogue fixtures; no downloaded or private text in tests."""

from collections import Counter
import gzip
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from corpus.common import digest, write_json
from corpus.english import check, load_lock, prepare, validate_conversation, verify_raw
from corpus.clean.dialogue import (Archive, Files, abcd, convai2, conversation,
                                  eligible_oasst, sgd, taskmaster, topical, turn)


def archive(path, files):
    with tarfile.open(path, 'w:gz') as handle:
        for name, data in files.items():
            if isinstance(data, str):
                data = data.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            handle.addfile(info, io.BytesIO(data))


class EnglishCorpusTests(unittest.TestCase):
    def fixture(self, root):
        (root / 'raw/bst').mkdir(parents=True)
        (root / 'licenses').mkdir()
        notice = root / 'licenses/fixture.txt'
        notice.write_text('Synthetic notice\n')
        raw = root / 'raw/bst/source.tar.gz'
        files = {}
        for split in ('train', 'valid', 'test'):
            files[split + '.json'] = json.dumps([{
                'personas': ['EXCLUDED PROFILE'], 'additional_context': 'EXCLUDED CONTEXT',
                'free_turker_utterance': 'EXCLUDED STARTER',
                'suggestions': ['EXCLUDED SUGGESTION'],
                'dialog': [[0, f"I'm ready, {split}!"], [1, 'Yes — let’s go.\nNext line.']],
            }])
        archive(raw, files)
        source = {'id': 'bst', 'reader': 'bst', 'revision': 'a' * 40, 'license': 'fixture',
                  'files': [{'path': 'source.tar.gz', 'size': raw.stat().st_size,
                             'sha256': digest(raw), 'url': 'https://example.invalid/source'}],
                  'documents': [{'path': 'licenses/fixture.txt', 'size': notice.stat().st_size,
                                 'sha256': digest(notice), 'url': 'https://example.invalid/license'}]}
        write_json(root / 'sources.lock.json', {'schema_version': 1, 'language': 'en', 'sources': [source]})
        return source

    def test_complete_offline_bundle_preserves_splits_bytes_and_excludes_context(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            out = root / 'bundle'
            report = prepare(['all'], out, root / 'raw', root / 'sources.lock.json')
            self.assertEqual(report['totals']['conversations'], 3)
            self.assertEqual(report['totals']['turns'], 6)
            row = json.loads((out / 'bst/train.jsonl').read_text())
            self.assertEqual([t['text'] for t in row['turns']],
                             ["I'm ready, train!", 'Yes — let’s go.\nNext line.'])
            self.assertNotIn('EXCLUDED', (out / 'bst/train.jsonl').read_text())
            self.assertEqual(row['split'], 'train')
            # A bundle is frozen and checks its copied lock, not today's selection.
            (root / 'sources.lock.json').unlink()
            self.assertEqual(check(out), report)
            with self.assertRaises(FileExistsError):
                from corpus.common import new_directory
                with new_directory(out):
                    self.fail('Existing bundle must not be overwritten')

    def test_corrupt_raw_rejected_and_existing_bundle_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self.fixture(root)
            (root / 'raw/bst/source.tar.gz').write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                verify_raw(source, root / 'raw')
            with self.assertRaises(ValueError):
                prepare(['all'], root / 'bundle', root / 'raw', root / 'sources.lock.json')
            self.assertFalse((root / 'bundle').exists())

    def test_corrupt_prepared_text_and_attribution_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            out = root / 'bundle'
            prepare(['all'], out, root / 'raw', root / 'sources.lock.json')
            path = out / 'bst/train.jsonl'
            original = path.read_bytes()
            path.write_bytes(original.replace(b'ready', b'other'))
            with self.assertRaisesRegex(ValueError, 'checksum'):
                check(out)
            path.write_bytes(original)
            (out / 'licenses/fixture.txt').write_text('altered notice')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                check(out)

    def test_cross_split_group_rejected_without_publishing_partial_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            records = [conversation(s, 'fixture', s, 'synthetic', [turn('1', 'a', s)], group='same')
                       for s in ('train', 'test')]
            with patch('corpus.english.conversations', return_value=iter(records)):
                with self.assertRaisesRegex(ValueError, 'crosses splits'):
                    prepare(['all'], root / 'bundle', root / 'raw', root / 'sources.lock.json')
            self.assertFalse((root / 'bundle').exists())

    def test_abcd_actions_are_not_utterances(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'source.tar.gz'
            data = {'train': [{'convo_id': 'synthetic', 'original': [
                ['customer', "I'd like help."], ['action', 'EXCLUDED ACTION'],
                ['agent', 'Sure!']]}]}
            archive(path, {'root/data/abcd_v1.1.json.gz': gzip.compress(json.dumps(data).encode())})
            counts = Counter()
            with Archive(path) as handle:
                rows = list(abcd(handle, counts))
            self.assertEqual([t['text'] for t in rows[0]['turns']], ["I'd like help.", 'Sure!'])
            self.assertEqual(counts['excluded_action_records'], 1)

    def test_convai2_keeps_complete_dialogue_without_alternate_speaker_view(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'source.tar.gz'
            original = ('1 your persona: EXCLUDED\n1 Hi.\tHello!\n2 Ready?\tYes.\n'
                        '1 your persona: EXCLUDED\n1 __SILENCE__\tHi.\n2 Hello!\tReady?\n')
            archive(path, {'train_both_original.txt': original,
                           'valid_both_original.txt': '1 your persona: EXCLUDED\n1 Goodbye.\tBye!\n'})
            counts = Counter()
            with Archive(path) as handle:
                rows = list(convai2(handle, counts))
            self.assertEqual(len(rows), 2)
            self.assertEqual([t['text'] for t in rows[0]['turns']], ['Hi.', 'Hello!', 'Ready?', 'Yes.'])
            self.assertEqual(counts['excluded_alternate_speaker_views'], 1)

    def test_oasst_filters_and_branch_edges_are_explicit(self):
        row = {'lang': 'en', 'deleted': False, 'synthetic': False, 'review_result': True,
               'labels': {'name': ['quality', 'pii'], 'value': [0.9, 0]}}
        self.assertIsNone(eligible_oasst(row))
        for changes in ({'lang': 'zh'}, {'synthetic': True}, {'deleted': True},
                        {'review_result': None}, {'labels': None},
                        {'labels': {'name': ['pii'], 'value': [1]}}):
            self.assertIsNotNone(eligible_oasst(dict(row, **changes)))
        record = conversation('train', 'fixture', 'tree', 'human-assistant-tree', [
            turn('child-a', 'assistant', 'One reply.', parent='filtered-parent'),
            turn('child-b', 'assistant', 'Another reply.', parent='filtered-parent')])
        validate_conversation(record)
        self.assertEqual(record['turns'][0]['parent'], record['turns'][1]['parent'])

    def test_taskmaster_keeps_collection_methods_and_unassigned_splits(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'source.tar.gz'
            def row(identity):
                return {'conversation_id': identity, 'utterances': [
                    {'index': 0, 'speaker': 'USER', 'text': "I'd like a table."},
                    {'index': 1, 'speaker': '', 'text': 'For two?'}],
                    'instructions': 'EXCLUDED', 'apis': [{'text': 'EXCLUDED'}]}
            files = {f'root/TM-1-2019/train-dev-test/{name}.csv':
                     ('dlg-written\n' if name == 'train' else '') for name in ('train', 'dev', 'test')}
            files.update({'root/TM-1-2019/self-dialogs.json': json.dumps([row('dlg-written')]),
                          'root/TM-1-2019/woz-dialogs.json': json.dumps([row('dlg-spoken')]),
                          'root/TM-2-2020/data/music.json': json.dumps([row('dlg-music')]),
                          'root/TM-3-2020/data/data_00.json': json.dumps([row('dlg-ticket')]),
                          'root/TM-3-2020/splits/test/test-aa.tsv': 'EXCLUDED\tEXCLUDED\tdlg-ticket\n',
                          'root/TM-3-2020/splits/train/train-aa.tsv': 'EXCLUDED\tEXCLUDED\tdlg-ticket\n'})
            archive(path, files)
            with Archive(path) as handle:
                rows = list(taskmaster(handle, Counter()))
            byid = {r['group']: r for r in rows}
            self.assertEqual(byid['tm1:dlg-written']['split'], 'train')
            self.assertEqual(byid['tm1:dlg-spoken']['split'], 'unsplit')
            self.assertEqual(byid['tm2:dlg-music']['method'], 'human-spoken-woz')
            self.assertEqual(byid['tm3:dlg-ticket']['method'], 'human-written-self-dialogue')
            self.assertEqual(byid['tm3:dlg-ticket']['split'], 'unsplit')
            self.assertEqual(byid['tm3:dlg-ticket']['upstream_example_splits'], ['test', 'train'])
            self.assertEqual(byid['tm1:dlg-spoken']['turns'][1]['speaker'], 'unknown')
            self.assertNotIn('EXCLUDED', json.dumps(rows))

    def test_taskmaster_reused_ids_retain_distinct_text_and_group_variants(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'source.tar.gz'
            def row(text):
                return {'conversation_id': 'dlg-reused', 'utterances': [
                    {'index': 0, 'speaker': 'USER', 'text': text}]}
            files = {f'root/TM-1-2019/train-dev-test/{name}.csv': ''
                     for name in ('train', 'dev', 'test')}
            files['root/TM-2-2020/data/music.json'] = json.dumps([
                row('One request.'), row('One request.'), row('A different request.')])
            archive(path, files)
            counts = Counter()
            with Archive(path) as handle:
                rows = list(taskmaster(handle, counts))
            self.assertEqual(len(rows), 2)
            self.assertNotEqual(rows[0]['id'], rows[1]['id'])
            self.assertEqual(rows[0]['group'], rows[1]['group'])
            self.assertEqual(counts['excluded_exact_duplicate_records'], 1)

    def test_topical_retains_rare_frequent_splits_and_only_messages(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'conversations').mkdir()
            entries = []
            for name in ('train', 'valid_freq', 'valid_rare', 'test_freq', 'test_rare'):
                path = root / 'conversations' / (name + '.json')
                path.write_text(json.dumps({name: {'article_url': 'EXCLUDED', 'content': [
                    {'agent': 'agent_1', 'message': 'Interesting!', 'knowledge_source': ['EXCLUDED']}]
                }}))
                entries.append({'path': str(path.relative_to(root))})
            with Files(root, entries) as handle:
                rows = list(topical(handle, Counter()))
            self.assertEqual({r['split'] for r in rows},
                             {'train', 'validation-frequent', 'validation-rare', 'test-frequent', 'test-rare'})
            self.assertNotIn('EXCLUDED', json.dumps(rows))

    def test_sgd_imports_utterances_without_frames_or_schema(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'source.tar.gz'
            row = {'dialogue_id': 'fixture', 'turns': [{'speaker': 'USER',
                   'utterance': 'Tomorrow, please.', 'frames': [{'text': 'EXCLUDED'}]}]}
            archive(path, {'root/dev/dialogues_001.json': json.dumps([row]),
                           'root/dev/schema.json': json.dumps([{'text': 'EXCLUDED'}])})
            with Archive(path) as handle:
                rows = list(sgd(handle, Counter()))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['split'], 'validation')
            self.assertEqual(rows[0]['group'], 'validation:fixture')
            self.assertEqual(rows[0]['turns'][0]['text'], 'Tomorrow, please.')
            self.assertNotIn('EXCLUDED', json.dumps(rows))

    def test_archive_traversal_and_lock_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            path = root / 'unsafe.tar.gz'
            archive(path, {'../outside': 'synthetic'})
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                Archive(path)
            lock = json.loads((root / 'sources.lock.json').read_text())
            lock['sources'][0]['files'][0]['path'] = '../outside'
            write_json(root / 'sources.lock.json', lock)
            with self.assertRaises(ValueError):
                load_lock(root / 'sources.lock.json', root)


if __name__ == '__main__':
    unittest.main()
