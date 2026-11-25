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
    def test_unused_excludes_parent_and_ancestor_text_groups_and_long_paragraphs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path, lock, raw = fixture(root / 'fixture')
            ancestor = root / 'ancestor'
            prepare(config_path, ancestor, lock, raw)
            archive = raw / 'fixture/source.tar.gz'

            def replace_archive(records):
                with tarfile.open(archive, 'w:gz') as handle:
                    for name, text in records:
                        content = text.encode()
                        member = tarfile.TarInfo('fixture/' + name)
                        member.size = len(content)
                        handle.addfile(member, io.BytesIO(content))
                declaration = read_json(lock)
                declaration['sources'][0].update(size=archive.stat().st_size, sha256=file_hash(archive))
                write_json(lock, declaration)

            def fresh_records(start):
                return [(f'zh/{i}.md', f'这是新对话编号{i}的完整内容，今天下午我们先去附近的超市买点水果，然后一起回家做饭。')
                        for i in range(start, start + 80)]

            replace_archive(fresh_records(80))
            parent = root / 'parent'
            prepare(config_path, parent, lock, raw, parent_data=ancestor)
            old_rows = [next(read_jsonl(path / 'train.documents.jsonl')) for path in (parent, ancestor)]
            records = fresh_records(160)
            for index, row in enumerate(old_rows):
                records.extend([
                    (f'zh/copied-{index}.md', row['text']),
                    (row['group'], f'来自旧会话的新一句话，编号{index}，应该一起排除。'),
                    (f'zh/paragraph-{index}.md', '新开头，保留自己的表达。\n\n' +
                     next(line for line in row['text'].splitlines() if len(normalized(line)) >= 32)),
                ])
            replace_archive(records)
            config = read_json(config_path)
            config['data']['exclude_parent_documents'] = True
            write_json(config_path, config)
            output = root / 'unused'
            manifest = prepare(config_path, output, lock, raw, parent_data=parent, ancestor_data=[ancestor])
            counts = manifest['source_counts']['fixture']
            self.assertEqual(counts['excluded_parent_documents'], 2)
            self.assertEqual(counts['excluded_parent_group_documents'], 2)
            self.assertEqual(counts['excluded_parent_paragraph_documents'], 2)
            self.assertEqual(sum(s['documents'] for s in manifest['splits'].values()), 80)
            for split in ('train', 'validation', 'test'):
                for row in read_jsonl(output / f'{split}.documents.jsonl'):
                    self.assertEqual(split_for('fixture', row['group'], config), split)
                    self.assertIn('这是新对话编号', row['text'])
            self.assertEqual(counts['train_targets'], manifest['splits']['train']['targets'])
            with self.assertRaisesRegex(ValueError, 'requires --parent-data'):
                prepare(config_path, root / 'no-parent', lock, raw)

    def test_si_extract_without_quota_preserves_complete_conversations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path, lock, raw = fixture(root / 'fixture')
            parent = root / 'parent'
            prepare(config_path, parent, lock, raw)
            source = root / 'prepared/si'
            source.mkdir(parents=True)
            next_line = 1
            with (source / 'text.txt').open('w', encoding='utf-8') as text, \
                    (source / 'documents.jsonl').open('w', encoding='utf-8') as metadata:
                for index in range(80):
                    value = f'今天安排第{index}次聚餐。\n好呀，第{index}次我们一起去。\n\n'
                    text.write(value)
                    metadata.write(json.dumps({
                        'origin': f'chat.txt/conversation:{index}', 'first_line': next_line,
                        'lines': 3, 'path': 'chat.txt', 'conversation': index,
                    }) + '\n')
                    next_line += 3
            files = {p.name: {'sha256': file_hash(p), 'bytes': p.stat().st_size}
                     for p in source.iterdir()}
            write_json(source / 'manifest.json', {
                'schema_version': 2, 'extraction_contract': 'complete-simplified-text-lines-v2',
                'source': {'id': 'si'}, 'files': files,
            })
            config = read_json(config_path)
            config['data']['sources'] = ['si']
            write_json(config_path, config)
            manifest = prepare(config_path, root / 'adapted', lock, raw, parent_data=parent,
                               prepared_root=root / 'prepared', ancestor_data=[parent])
            self.assertEqual(manifest['ancestor_dataset_ids'], [manifest['parent_dataset_id']])
            self.assertEqual(sum(s['documents'] for s in manifest['splits'].values()), 80)
            for split in ('train', 'validation', 'test'):
                for row in read_jsonl(root / 'adapted' / f'{split}.documents.jsonl'):
                    self.assertEqual(split_for('si', row['group'], config), split)
                    self.assertIn('\n好呀', row['text'])
            self.assertTrue((root / 'adapted/metadata/si/manifest.json').is_file())

    def test_prepared_dialogue_joins_text_and_retains_upstream_splits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path, lock, raw = fixture(root / 'fixture')
            prepare(config_path, root / 'parent', lock, raw)
            source = root / 'prepared/dialogue'
            source.mkdir(parents=True)
            (source / 'attribution').mkdir()
            (source / 'attribution/notice.txt').write_text('Synthetic fixture', encoding='utf-8')
            records = [
                ('train', 1, '下午碰头，记得把会议纪要也带上。\n这次就在楼下那家店。\n'),
                ('test', 2, '明早开门之前我去取快递。\n'),
                ('dev', 3, '到了先帮我跟前台打声招呼。\n'),
                ('test', 2, '包裹上贴着蓝色标签。\n'),
            ]
            next_line = 1
            with (source / 'text.txt').open('w', encoding='utf-8') as text, \
                    (source / 'documents.jsonl').open('w', encoding='utf-8') as documents:
                for index, (split, conversation, value) in enumerate(records):
                    text.write(value)
                    lines = value.count('\n')
                    documents.write(json.dumps({
                        'origin': f'fixture/{index}', 'path': f'{split}.json', 'dataset': 'example',
                        'conversation': conversation, 'split': split, 'first_line': next_line, 'lines': lines,
                    }) + '\n')
                    next_line += lines
            files = {path.relative_to(source).as_posix(): {'sha256': file_hash(path), 'bytes': path.stat().st_size}
                     for path in source.rglob('*') if path.is_file()}
            write_json(source / 'manifest.json', {
                'schema_version': 2, 'extraction_contract': 'complete-simplified-text-lines-v2',
                'source': {'id': 'dialogue'}, 'files': files,
            })
            config = read_json(config_path)
            config['data'].update(sources=['dialogue'], train_target_quotas={'dialogue': {'example': 12}})
            write_json(config_path, config)
            output = root / 'adapted'
            manifest = prepare(config_path, output, lock, raw, parent_data=root / 'parent',
                               prepared_root=root / 'prepared')
            self.assertTrue((output / 'metadata/dialogue/attribution/notice.txt').is_file())
            tests = list(read_jsonl(output / 'test.documents.jsonl'))
            self.assertEqual({row['origin'] for row in tests}, {'fixture/1', 'fixture/3'})
            self.assertEqual(len({row['group'] for row in tests}), 1)
            self.assertEqual(manifest['source_counts']['dialogue']['subsources']['example']['validation_documents'], 1)
            self.assertEqual(next(read_jsonl(output / 'train.documents.jsonl'))['text'], records[0][2].strip())

    def test_chat_quotas_freeze_vocabulary_and_reject_cross_parent_split_duplicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path, lock, raw = fixture(root / 'fixture')
            parent = prepare(config_path, root / 'parent', lock, raw)
            config = read_json(config_path)
            config['seed'] += 1
            config['data']['train_target_quotas'] = {'fixture': 1200}
            write_json(config_path, config)
            adapted = prepare(config_path, root / 'adapted', lock, raw, parent_data=root / 'parent')
            self.assertEqual(adapted['parent_dataset_id'], parent['dataset_id'])
            self.assertEqual(adapted['tokenizer_digest'], parent['tokenizer_digest'])
            source = adapted['source_counts']['fixture']
            self.assertGreater(source['cross_parent_split_documents'], 0)
            self.assertGreaterEqual(source['train_targets'], 1200)
            self.assertEqual(source['train_targets'], adapted['splits']['train']['targets'])
            for split in ('train', 'validation', 'test'):
                parent_ids = {row['id'] for row in read_jsonl(root / 'parent' / f'{split}.documents.jsonl')}
                adapted_ids = {row['id'] for row in read_jsonl(root / 'adapted' / f'{split}.documents.jsonl')}
                self.assertTrue(adapted_ids and adapted_ids <= parent_ids)

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
