"""Raw extraction regressions: retain numbers, punctuation, short text and repeats."""

from collections import Counter
import bz2
import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_raw_text import extract, raw_documents
from chatbot_sources import DOUBAN, FILES, PTT_V1, PTT_V2, WEIBO, chatbot_snapshot
from local_sources import snapshot
from common import digest


class RawTextPreparationTests(unittest.TestCase):
    def test_chatbot_import_preserves_turns_splits_and_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / 'raw'
            fixtures = {
                'chatterbot-1k/chinese/fixture.yml': 'conversations:\n- - 測試\n  - 好\n  - 好\n',
                DOUBAN[1]: '0\t排除\t排除\n1\t測試\tEnglish 2026\t好\n',
                PTT_V1: '新版覆蓋\t舊資料\n',
                PTT_V2: 'question,answer\n測試,沒有資料\n"繁體,標點","保留\n第二行"\n',
                FILES['qingyun'][0]: '問題|回答\n',
                FILES['subtitle'][0]: 'E\nM 字/幕\nE\nM 重複\n',
                FILES['tieba'][0]: '留言\t使用 English spaces\t回覆\n',
                WEIBO[0]: '貼文\n',
                WEIBO[1]: '回覆\n',
                FILES['xiaohuangji'][0]: b'E\nM \xff\nM test\n',
                'licenses/fixture.txt': 'Synthetic fixture notice.',
            }
            for name, value in fixtures.items():
                path = raw / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value.encode() if isinstance(value, str) else value)
            out = root / 'prepared'
            source = chatbot_snapshot(raw)
            manifest = extract(source, raw, out)
            self.assertEqual(source['missing_datasets'], [])
            self.assertEqual(source['missing_douban_splits'], ['train', 'test'])
            self.assertEqual(source['datasets']['ptt'], [PTT_V2])
            self.assertEqual((out / 'text.txt').read_text().splitlines(), [
                '测试', '好', '好', '测试', 'English 2026', '好', '繁体,标点', '保留', '第二行',
                '问题', '回答', '字幕', '重复', '留言', '使用 English spaces', '回复', '贴文', '回复',
                '\ufffd', 'test',
            ])
            rows = [json.loads(line) for line in (out / 'documents.jsonl').read_text().splitlines()]
            self.assertEqual([row['turn'] for row in rows[:3]], [0, 1, 2])
            self.assertEqual([row['split'] for row in rows[3:6]], ['dev'] * 3)
            self.assertEqual((rows[7]['first_line'], rows[7]['lines']), (8, 2))
            self.assertEqual([row['role'] for row in rows if row['dataset'] == 'weibo'], ['post', 'response'])
            self.assertEqual(manifest['counts']['excluded_douban_negatives'], 1)
            self.assertEqual(manifest['counts']['excluded_ptt_placeholders'], 1)
            self.assertEqual(manifest['counts']['invalid_utf8_lines'], 1)
            self.assertEqual(manifest['dataset_documents']['tieba'], 3)
            self.assertIn('attribution/licenses/fixture.txt', manifest['files'])
            self.assertIn('attribution/chinese-chatbot-corpus.md', manifest['files'])
            self.assertEqual(extract(source, raw, out), manifest)

    def test_chatbot_misaligned_weibo_files_do_not_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            post, reply = (root / name for name in WEIBO)
            post.parent.mkdir()
            post.write_text('貼文\n')
            with self.assertRaisesRegex(ValueError, 'both Weibo files'):
                chatbot_snapshot(root)
            reply.write_text('回覆\n多了一行\n')
            output = root / 'out'
            with self.assertRaisesRegex(ValueError, 'lengths differ at row 2'):
                extract(chatbot_snapshot(root), root, output)
            self.assertFalse(output.exists())

    def local_manifest(self, root, datasets):
        for dataset in datasets:
            for entry in dataset['files']:
                path = root / dataset['id'] / entry['path']
                entry.update(size=path.stat().st_size, sha256=digest(path))
        (root / 'download-manifest.json').write_text(json.dumps({
            'schema_version': 1, 'kind': 'raw-conversation-downloads', 'sources': datasets}))
        return snapshot('dialogue', root)

    def test_si_corpus_command_prepares_only_three_local_collections(self):
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / 'raw'
            dialogue = raw / 'dialogue'
            kdconv = dialogue / 'kdconv/train.json'
            kdconv.parent.mkdir(parents=True)
            kdconv.write_text(json.dumps([{'name': 'fixture', 'messages': [{'message': '對話。'}]}]))
            self.local_manifest(dialogue, [{'id': 'kdconv', 'files': [{'path': 'train.json'}]}])
            chatbot = raw / 'chinese-corpus' / PTT_V1
            chatbot.parent.mkdir(parents=True)
            chatbot.write_text('問題\t回答\n')
            si = raw / 'si' / 'fixture.txt'
            si.parent.mkdir()
            si.write_text('我們。\n')
            (raw / 'lccc').mkdir()
            output = Path(temporary) / 'prepared/si-corpus'
            script = Path(__file__).resolve().parents[1] / 'prepare_si_raw_text.py'
            command = [sys.executable, script, '--raw-root', raw, '--output', output]
            expected = {'dialogue': '对话。\n', 'chinese-corpus': '问题\n回答\n', 'si': '我们。\n\n'}
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual({path.name for path in output.iterdir()}, expected.keys())
            for name, text in expected.items():
                bundle = output / name
                self.assertEqual((bundle / 'text.txt').read_text(), text)
                self.assertTrue((bundle / 'manifest.json').is_file())
                self.assertTrue((bundle / 'documents.jsonl').is_file())

            (raw / 'chinese-corpus').rename(raw / 'chinese-chatbot-corpus')
            repeated = subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertEqual(repeated.stdout.count('Verified completed raw-text extraction'), 3)

    def test_si_keeps_conversations_english_repeats_and_simplifies_only_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / 'raw'
            raw.mkdir()
            a = raw / 'a.txt'
            a.write_bytes('我們用 Python tools 2026。\r\n好。\r\n\r\n好。\r\n'.encode())
            (raw / 'z.txt').write_text('測試。\n')
            original = a.read_bytes()
            source = snapshot('si', raw)
            out = root / 'prepared'
            result = extract(source, raw, out)
            self.assertEqual((out / 'text.txt').read_text(),
                             '我们用 Python tools 2026。\n好。\n\n好。\n\n测试。\n\n')
            rows = [json.loads(line) for line in (out / 'documents.jsonl').read_text().splitlines()]
            self.assertEqual([(row['first_line'], row['lines']) for row in rows], [(1, 3), (4, 2), (6, 2)])
            self.assertEqual([row['path'] for row in rows], ['a.txt', 'a.txt', 'z.txt'])
            self.assertEqual(rows[1]['source_first_line'], 4)
            self.assertEqual(result['normalization']['config'], 't2s')
            self.assertEqual(a.read_bytes(), original)
            self.assertEqual(extract(source, raw, out), result)
            with patch('prepare_raw_text.importlib.metadata.version', return_value='changed-version'):
                with self.assertRaisesRegex(ValueError, 'normalization'):
                    extract(source, raw, out)
            (raw / 'new.txt').write_text('新增。')
            with self.assertRaisesRegex(ValueError, 'changed before'):
                extract(source, raw, root / 'other')
            with self.assertRaisesRegex(ValueError, 'different inputs'):
                extract(snapshot('si', raw), raw, out)

    def test_local_source_change_during_read_rolls_back(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / 'raw'
            raw.mkdir()
            path = raw / 'a.txt'
            path.write_text('測試。\n')
            source = snapshot('si', raw)
            def changing_reader(*args):
                yield 'fixture', '測試。', {}
                path.write_text('修改後。\n')
            with patch('prepare_raw_text.raw_documents', changing_reader):
                with self.assertRaisesRegex(ValueError, 'changed during'):
                    extract(source, raw, root / 'out')
            self.assertFalse((root / 'out').exists())

    def test_empty_and_escaping_si_sources_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / 'raw'
            raw.mkdir()
            with self.assertRaisesRegex(ValueError, 'no TXT'):
                snapshot('si', raw)
            (root / 'outside.txt').write_text('合成。')
            (raw / 'escape.txt').symlink_to(root / 'outside.txt')
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                snapshot('si', raw)

    def test_dialogue_formats_preserve_identity_and_skip_duplicate_lccc(self):
        import zipfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / 'raw'
            kd = raw / 'kdconv/data/train.json'
            kd.parent.mkdir(parents=True)
            kd.write_text(json.dumps([{'name': 'fixture', 'messages': [
                {'message': '我們用 API 2026。'}, {'message': '好。'}]}]))
            cross = raw / 'crosswoz/data/val.json.zip'
            cross.parent.mkdir(parents=True)
            with zipfile.ZipFile(cross, 'w') as archive:
                archive.writestr('val.json', json.dumps({'fixture': {'messages': [
                    {'content': '換一個。', 'role': 'usr'}, {'content': '沒問題。', 'role': 'sys'}]}}))
            lccc = raw / 'lccc-base/train.jsonl.gz'
            lccc.parent.mkdir(parents=True)
            with gzip.open(lccc, 'wt') as handle:
                handle.write(json.dumps(['我們 用 Python tools 2017 年 。', '好。', '好。']) + '\n')
            license = raw / 'licenses/fixture.txt'
            license.parent.mkdir()
            license.write_text('Synthetic attribution fixture\n')
            datasets = [
                {'id': 'kdconv', 'files': [{'path': 'data/train.json'}], 'documents': [
                    {'path': 'licenses/fixture.txt', 'size': license.stat().st_size, 'sha256': digest(license)}]},
                {'id': 'crosswoz', 'files': [{'path': 'data/val.json.zip'}]},
                {'id': 'lccc-base', 'files': [{'path': 'train.jsonl.gz'}]}]
            source = self.local_manifest(raw, datasets)
            output = root / 'out'
            result = extract(source, raw, output)
            self.assertEqual((output / 'text.txt').read_text().splitlines(), [
                '我们用 API 2026。', '好。', '换一个。', '没问题。'])
            rows = [json.loads(line) for line in (output / 'documents.jsonl').read_text().splitlines()]
            self.assertEqual({row['dataset'] for row in rows}, {'kdconv', 'crosswoz'})
            self.assertEqual(rows[2]['dataset'], 'crosswoz')
            self.assertEqual(rows[2]['split'], 'val')
            self.assertEqual(rows[2]['conversation'], 'fixture')
            self.assertEqual(rows[2]['role'], 'usr')
            self.assertEqual(rows[-1]['turn'], 1)
            self.assertIn('attribution/licenses/fixture.txt', result['files'])
            kd.write_text('[]')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                snapshot('dialogue', raw)

    def test_oasst_chinese_messages_keep_parent_edges_without_joining_siblings(self):
        import pyarrow as arrow
        import pyarrow.parquet as parquet
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'raw/oasst1/data/validation-fixture.parquet'
            path.parent.mkdir(parents=True)
            rows = [
                {'message_id': 'root', 'parent_id': None, 'message_tree_id': 'tree', 'lang': 'zh', 'role': 'prompter', 'text': '怎麼用？'},
                {'message_id': 'a', 'parent_id': 'root', 'message_tree_id': 'tree', 'lang': 'zh', 'role': 'assistant', 'text': '試試 A。'},
                {'message_id': 'b', 'parent_id': 'root', 'message_tree_id': 'tree', 'lang': 'zh', 'role': 'assistant', 'text': '試試 B。'},
                {'message_id': 'en', 'parent_id': None, 'message_tree_id': 'other', 'lang': 'en', 'role': 'prompter', 'text': 'English only.'}]
            parquet.write_table(arrow.Table.from_pylist(rows), path)
            source = self.local_manifest(root / 'raw', [{'id': 'oasst1', 'files': [{'path': 'data/validation-fixture.parquet'}]}])
            result = extract(source, root / 'raw', root / 'out')
            self.assertEqual((root / 'out/text.txt').read_text(), '怎么用？\n试试 A。\n试试 B。\n')
            origins = [json.loads(line) for line in (root / 'out/documents.jsonl').read_text().splitlines()]
            self.assertEqual([row['parent_id'] for row in origins], [None, 'root', 'root'])
            self.assertTrue(all(row['split'] == 'validation' for row in origins))
            self.assertEqual(result['counts']['non_chinese_messages'], 1)

    def test_mc4_keeps_complete_lines_short_english_and_repeated_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.gz'
            title = '关于2017年候选人的通知，金额12.50元。短句、English co-op！'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                for text in (title, title, 'English only 2026.', '短', '正文' * 70):
                    handle.write(json.dumps({'text': text, 'url': 'https://example.invalid/'}) + '\n')
            source = {'id': 'synthetic', 'kind': 'mc4'}
            output = root / 'output'
            manifest = extract(source, archive, output)
            lines = (output / 'text.txt').read_text().splitlines()
            self.assertEqual(lines[:4], [title, title, 'English only 2026.', '短'])
            self.assertEqual(lines[4], '正文' * 70)
            self.assertEqual(manifest['counts']['records_read'], 5)
            origins = [json.loads(line) for line in (output / 'documents.jsonl').read_text().splitlines()]
            self.assertEqual([row['first_line'] for row in origins], [1, 2, 3, 4, 5])
            self.assertEqual(origins[0]['url'], 'https://example.invalid/')
            self.assertEqual(extract(source, archive, output), manifest)
            (output / 'text.txt').write_text('Changed')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                extract(source, archive, output)

    def test_lccc_restores_han_tokens_without_joining_english_or_removing_digits(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'dialogue.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps(['我们 测试 ， 使用 Python tools 2017 年 。', '短 句']) + '\n')
            rows = list(raw_documents({'kind': 'lccc'}, archive, Counter()))
            self.assertEqual(rows, [('row:1/turn:0', '我们测试，使用 Python tools 2017 年。', {}),
                                    ('row:1/turn:1', '短句', {})])

    def test_wikipedia_keeps_article_title_numbers_punctuation_and_english(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'wiki.bz2'
            archive.write_bytes(bz2.compress((
                '<mediawiki><page><title>标题2017</title><ns>0</ns><id>1</id>'
                '<revision><id>11</id><text>正文2017年，English tools。\n短。</text></revision></page>'
                '<page><title>模板</title><ns>10</ns><id>2</id>'
                '<revision><id>12</id><text>非正文</text></revision></page></mediawiki>'
            ).encode()))
            result = list(raw_documents({'kind': 'wikipedia'}, archive, Counter()))
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0][1], '标题2017\n\n正文2017年，English tools。\n短。')

    def test_utf8_serialization_and_failed_record_do_not_publish_partial_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps({'text': '保持\ud800数字2017\r\n下一行'}) + '\n')
            result = extract({'id': 'fixture', 'kind': 'mc4'}, archive, root / 'valid')
            self.assertEqual((root / 'valid/text.txt').read_text(), '保持数字2017\n下一行\n')
            self.assertEqual(result['counts']['surrogates_removed'], 1)
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps({'text': '正常2017。'}) + '\n')
                handle.write(json.dumps({'text': 42}) + '\n')
            with self.assertRaisesRegex(ValueError, 'row 2'):
                extract({'id': 'fixture', 'kind': 'mc4'}, archive, root / 'invalid')
            self.assertFalse((root / 'invalid').exists())


if __name__ == '__main__':
    unittest.main()
