from collections import defaultdict
import gzip
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from llm.pinyin_to_text.common import read_jsonl, normalized
from llm.reranker_small.data import load_bundle
from llm.reranker_small.fixtures import fixture
from llm.reranker_small.prepare import prepare, split_for
from llm.reranker_small.settings import file_hash, load_config, read_json, write_json


class DataTests(unittest.TestCase):
    def test_whole_documents_punctuation_english_and_window_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path, lock, raw = fixture(root / 'fixture')
            first = prepare(config_path, root / 'data', lock, raw)
            second = prepare(config_path, root / 'repeat', lock, raw)
            self.assertEqual(first['dataset_id'], second['dataset_id'])
            self.assertEqual(first['files'], second['files'])
            _, tokenizer, datasets = load_bundle(root / 'data', load_config(config_path), ('train', 'validation', 'test'))
            paragraph_splits = defaultdict(set)
            for split, dataset in datasets.items():
                offset = 0
                bounds = []
                records = list(read_jsonl(root / 'data' / f'{split}.documents.jsonl'))
                self.assertTrue(records)
                for row in records:
                    self.assertIn('English words。\n\n', row['text'])
                    ids = tokenizer.encode(row['text'])
                    self.assertEqual(dataset.tokens[offset:offset + len(ids)].tolist(), ids)
                    bounds.append((offset, offset + len(ids)))
                    offset += len(ids)
                    for line in row['text'].splitlines():
                        if len(normalized(line)) >= 32:
                            paragraph_splits[normalized(line)].add(split)
                self.assertEqual(offset, len(dataset.tokens))
                for start, count in dataset.windows:
                    self.assertTrue(any(a <= start and start + count <= b for a, b in bounds))
                self.assertEqual(dataset.target_count(range(len(dataset))), first['splits'][split]['targets'])
            self.assertTrue(all(len(splits) == 1 for splits in paragraph_splits.values()))
            with self.assertRaises(FileExistsError):
                prepare(config_path, root / 'data', lock, raw)

    def test_heldout_characters_do_not_fit_vocabulary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path, lock, raw = fixture(root / 'fixture')
            config = load_config(config_path)
            archive = raw / 'fixture/source.tar.gz'
            with tarfile.open(archive, 'w:gz') as handle:
                for index in range(80):
                    split = split_for('fixture', f'zh/{index}.md', config)
                    text = f'编号{index}的中文文档内容，English words。\n\n文档编号{index}用来检验严格的数据分组。'
                    if split != 'train':
                        text += '龘🧪'
                    member = tarfile.TarInfo(f'fixture/zh/{index}.md')
                    content = text.encode()
                    member.size = len(content)
                    handle.addfile(member, io.BytesIO(content))
            declaration = read_json(lock)
            declaration['sources'][0].update(size=archive.stat().st_size, sha256=file_hash(archive))
            write_json(lock, declaration)
            prepare(config_path, root / 'data', lock, raw)
            _, tokenizer, _ = load_bundle(root / 'data', config, ('validation',))
            self.assertNotIn('龘', tokenizer.lookup)
            self.assertNotIn('🧪', tokenizer.lookup)
            self.assertEqual(tokenizer.decode(tokenizer.encode('龘🧪')), '龘🧪')

    def test_lccc_conversation_turns_share_a_split_and_keep_english_spaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, lock, raw = fixture(root / 'fixture')
            archive = raw / 'fixture/turns.jsonl.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                for index in range(80):
                    handle.write(json.dumps([f'这是 第{index}条 对话 内容 使用 Python programming',
                                             f'今天 第{index}条 回复 讨论 中文 模型']) + '\n')
            declaration = read_json(lock)
            declaration['sources'][0].update(kind='lccc', path=archive.name, size=archive.stat().st_size,
                                             sha256=file_hash(archive))
            write_json(lock, declaration)
            prepare(config, root / 'data', lock, raw)
            groups = defaultdict(set)
            count = 0
            for split in ('train', 'validation', 'test'):
                for row in read_jsonl(root / 'data' / f'{split}.documents.jsonl'):
                    groups[row['group']].add(split)
                    count += 1
                    if 'Python' in row['text']:
                        self.assertIn('Python programming', row['text'])
            self.assertEqual(count, 160)
            self.assertEqual(len(groups), 80)
            self.assertTrue(all(len(splits) == 1 for splits in groups.values()))

    def test_bad_archive_leaves_no_prepared_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, lock, raw = fixture(root / 'fixture')
            archive = raw / 'fixture/source.tar.gz'
            value = bytearray(archive.read_bytes())
            value[-1] ^= 1
            archive.write_bytes(value)
            with self.assertRaises(ValueError):
                prepare(config, root / 'data', lock, raw)
            self.assertFalse((root / 'data').exists())
            self.assertEqual(archive.read_bytes(), value)

    def test_shared_long_paragraph_excludes_later_cross_split_document(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path, lock, raw = fixture(root / 'fixture')
            config = load_config(config_path)
            members = {split: [i for i in range(80) if split_for('fixture', f'zh/{i}.md', config) == split]
                       for split in ('train', 'validation', 'test')}
            train_id, validation_id = members['train'][0], members['validation'][0]
            common = '这是两份不同文档共享的足够长的中文段落，用来验证同一段正文不能同时进入训练集与验证集。'
            order = [train_id, validation_id, *[i for i in range(80) if i not in (train_id, validation_id)]]
            archive = raw / 'fixture/source.tar.gz'
            with tarfile.open(archive, 'w:gz') as handle:
                for index in order:
                    text = f'独立文档编号{index}，保留中文正文。\n\n'
                    text += common if index in (train_id, validation_id) else f'另一个文档编号{index}包含它自己的中文段落内容与 English words。'
                    content = text.encode()
                    member = tarfile.TarInfo(f'fixture/zh/{index}.md')
                    member.size = len(content)
                    handle.addfile(member, io.BytesIO(content))
            declaration = read_json(lock)
            declaration['sources'][0].update(size=archive.stat().st_size, sha256=file_hash(archive))
            write_json(lock, declaration)
            manifest = prepare(config_path, root / 'data', lock, raw)
            self.assertGreaterEqual(manifest['source_counts']['fixture']['cross_split_paragraph_documents'], 1)
            records = [row for split in ('train', 'validation', 'test')
                       for row in read_jsonl(root / 'data' / f'{split}.documents.jsonl')]
            self.assertIn(f'zh/{train_id}.md', {row['origin'] for row in records})
            self.assertNotIn(f'zh/{validation_id}.md', {row['origin'] for row in records})
