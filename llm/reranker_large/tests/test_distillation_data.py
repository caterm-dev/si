"""Authored synthetic documents only; no real corpus or Qwen scoring."""

from collections import Counter
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import torch

from llm.pinyin_to_text.common import file_hash, read_json, write_json, write_jsonl
from llm.reranker_large.data import load_pools
from llm.reranker_large.fixtures import SyntheticTeacher
from llm.reranker_large.prepare import prepare_documents
from llm.reranker_large.settings import ROOT
from llm.reranker_large.scoring import forward_pool, validate_pool
from llm.reranker_large.teacher import cache_teacher
from llm.reranker_large.train import train
from llm.reranker_small.model import CharacterLM
from llm.reranker_small.runtime import atomic_checkpoint
from llm.reranker_small.tokenizer import Tokenizer

spec = importlib.util.spec_from_file_location('si_distillation_producer', ROOT / 'scripts/distillation_data.py')
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


class FakeEngine:
    def candidates(self, spelling, context, limit):
        return [dict(text='登录', language='zh-Hans'), dict(text='登陆', language='zh-Hans')]


class DistillationDataTests(unittest.TestCase):
    def test_sixteen_token_candidate_and_context_fit_without_truncation(self):
        config = read_json(ROOT / 'configs/smoke.json')
        config['scoring'].update(context_tokens=16, candidate_tokens=16)
        tokenizer = Tokenizer(512, ['你', '好'])
        row = dict(context='好' * 16, input='ni', observed_text='你' * 16,
                   candidates=[dict(text='你' * 16, language='zh-Hans'), dict(text='好' * 16, language='zh-Hans')])
        self.assertTrue(validate_pool(row, tokenizer, config))
        model = CharacterLM(config['model'], tokenizer.active_ids).eval()
        scores, observed_loss = forward_pool(model, tokenizer, row, torch.device('cpu'), config['scoring'])
        self.assertTrue(torch.isfinite(scores).all() and torch.isfinite(observed_loss))
        row['candidates'][0]['text'] += '你'
        self.assertFalse(validate_pool(row, tokenizer, config))

    def test_source_lock_excludes_noncorpus_files_and_detects_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('dialogues/a.txt', 'workbuddy/role.txt', 'workbuddy/scripts/helper.txt',
                         'workbuddy/.memory/private.txt', 'dialogues/synthetic-fourth-position-20261123.txt'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('今天需要登录。\n明天也可以。\n\n', encoding='utf-8')
            with contextlib.redirect_stdout(io.StringIO()):
                producer.freeze_sources(root, ROOT / 'configs/distillation-data.json', root / 'lock.json')
            lock = read_json(root / 'lock.json')
            self.assertEqual([e['path'] for e in lock['files']], ['dialogues/a.txt', 'workbuddy/role.txt'])
            producer.verify_sources(root, lock)
            (root / 'dialogues/a.txt').write_text('Changed source.\n')
            with self.assertRaisesRegex(ValueError, 'source changed'):
                producer.verify_sources(root, lock)

    def test_ambiguous_longest_reading_is_not_guessed(self):
        db = sqlite3.connect(':memory:')
        db.execute('CREATE TABLE readings(text TEXT PRIMARY KEY, spelling TEXT)')
        db.executemany('INSERT INTO readings VALUES (?,?)', [('重', 'zhong'), ('新', 'xin'),
                                                            ('重新', None), ('登录', 'denglu')])
        readings = producer.DictionaryReadings(db)
        self.assertIsNone(readings.encode('重新'))
        self.assertEqual(readings.encode('API登录'), 'APIdenglu')
        self.assertIsNone(readings.encode('未知'))
        db.close()

    def test_context_lengths_long_targets_and_input_variants_are_reproducible(self):
        rules = read_json(ROOT / 'configs/distillation-data.json')
        rules['proposals_per_document'] = 5000
        text = '今天下午我们准备一起讨论项目然后登录系统检查配置最后确认是否可以发布。'
        tokenizer = Tokenizer(512, list(dict.fromkeys(text)))
        db = sqlite3.connect(':memory:')
        db.execute('CREATE TABLE readings(text TEXT PRIMARY KEY, spelling TEXT)')
        db.executemany('INSERT INTO readings VALUES (?,?)', [(c, 'shi') for c in set(text) if producer.HAN.fullmatch(c)])
        doc = dict(id='authored-example', text=text, split='train', source='si_dialogues', origin='fixture', grp='fixture')
        first = list(producer.proposals(doc, tokenizer, producer.DictionaryReadings(db), rules))
        self.assertEqual(first, list(producer.proposals(doc, tokenizer, producer.DictionaryReadings(db), rules)))
        rows = [row for row, reason in first if row]
        self.assertEqual({r['case']['context'] for r in rows}, {'none', 'short', 'medium', 'long'})
        self.assertEqual({r['case']['input'] for r in rows}, {'complete', 'partial', 'early', 'typo'})
        self.assertEqual({r['case']['target'] for r in rows}, {'single', 'word', 'phrase', 'long', 'very_long'})
        for row in rows:
            lo, hi = rules['context_buckets'][row['case']['context']]['tokens']
            self.assertTrue(lo <= len(tokenizer.encode(row['context'])) - 2 <= hi)
            self.assertIn(row['context'] + row['observed_text'], text)
            self.assertNotIn('reference_indices', row)
            self.assertFalse(row['reading_reviewed'])
        db.close()

    def test_template_groups_mask_slot_variants(self):
        self.assertEqual(producer.template('项目ABC将在12点上线。'), producer.template('项目XYZ将在23点上线。'))
        self.assertNotEqual(producer.template('今天去开会。'), producer.template('明天去吃饭。'))

    def test_real_rust_snapshot_readings_and_streamed_pools(self):
        binary = producer.REPO / 'target/release/si-cli'
        if not binary.exists():
            self.skipTest('Build Release si-cli for synthetic protocol integration')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'words.csv').write_text("text,reading,weight\n登录,deng'lu,100\n登陆,deng'lu,90\n重,zhong,10\n重,chong,10\n", encoding='utf-8')
            def cli(*args):
                subprocess.run([str(binary), *map(str, args)], check=True, capture_output=True)
            cli('lexicon', 'build', root / 'base.silex', '0', root / 'words.csv')
            (root / 'corpus.txt').write_text('登录 登陆\n', encoding='utf-8')
            cli('corpus', 'build', root / 'base.silex', root / 'base.sigram', root / 'corpus.txt')
            db = sqlite3.connect(':memory:')
            db.execute('CREATE TABLE readings(text TEXT PRIMARY KEY, spelling TEXT)')
            producer.index_readings(db, binary, root / 'base.silex', root)
            reader = producer.DictionaryReadings(db)
            self.assertEqual(reader.encode('登录'), 'denglu')
            self.assertIsNone(reader.encode('重'))
            engine = producer.Engine(binary, root / 'base.silex', root / 'base.sigram',
                                     producer.REPO / 'config/si.conf', read_json(ROOT / 'configs/distillation-data.json'))
            try:
                for context in ('', '今天需要', '', '我们现在需要'):
                    rows = engine.candidates('denglu', context, 12)
                    self.assertEqual({r['text'] for r in rows}, {'登录', '登陆'})
                    self.assertTrue(all(r['language'] == 'zh-Hans' for r in rows))
            finally:
                engine.close()
            db.close()

    def test_external_documents_freeze_resume_and_feed_existing_distillation(self):
        torch.set_num_threads(1)
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            rules = read_json(ROOT / 'configs/distillation-data.json')
            rules.update(source_shares={'si_dialogues': 1.0}, pools={s: 12 for s in producer.SPLITS},
                         max_si_file_share=1.0, proposals_per_document=80,
                         si_split_shares={'train': .6, 'validation': .2, 'test': .2})
            write_json(root / 'sampling.json', rules)
            raw = root / 'raw'
            (raw / 'dialogues').mkdir(parents=True)
            # Different Han endings ensure these are different template families.
            texts = [f'今天下午我们准备一起讨论项目然后登录系统检查配置最后确认是否可以发布{chr(0x4e10+i)}。'
                     for i in range(90)]
            (raw / 'dialogues/authored.txt').write_text('\n\n'.join(texts), encoding='utf-8')
            producer.freeze_sources(raw, root / 'sampling.json', root / 'sources.json')
            lock = read_json(root / 'sources.json')
            config = read_json(ROOT / 'configs/smoke.json')
            config['scoring'].update(context_tokens=16, candidate_tokens=16)
            config['training'].update(max_steps=1, validate_every=1, save_every=1)
            write_json(root / 'pretrain.json', config)
            write_json(root / 'provenance.json', dict(schema_version=1, sources=[dict(
                id='fixture', origin='SI-authored synthetic test data', revision='v1', license='GPL-3.0-only')]))
            alphabet = ''.join(sorted(set(''.join(texts))))
            write_jsonl(root / 'docs.jsonl', [dict(source='fixture', origin=s, group=s, split=s,
                        text='预训练' + chr(0x5100+i) + alphabet) for i, s in enumerate(producer.SPLITS)])
            manifest = prepare_documents(root / 'pretrain.json', root / 'docs.jsonl', root / 'provenance.json', root / 'lm')
            original_pin = file_hash(root / 'lm/manifest.json')
            tokenizer = Tokenizer.load(root / 'lm/tokenizer.json')
            db = sqlite3.connect(root / 'work.sqlite3')
            producer.index_documents(db, root / 'lm', manifest, raw, lock, rules)
            db.executemany('INSERT INTO readings VALUES (?,?)', [(c, 'shi') for c in set(alphabet) if producer.HAN.fullmatch(c)])
            db.commit()
            producer.generate(db, tokenizer, FakeEngine(), rules, config)
            pins = list(db.execute('SELECT id,row FROM pools ORDER BY id'))
            producer.generate(db, tokenizer, FakeEngine(), rules, config)
            self.assertEqual(pins, list(db.execute('SELECT id,row FROM pools ORDER BY id')))
            identity = dict(parent_lm_dataset_id=manifest['dataset_id'], fixture=True)
            result = producer.publish(db, root / 'pools', root / 'lm', manifest, tokenizer,
                                      config, rules, lock, identity, False)
            self.assertEqual({s: result['splits'][s]['pools'] for s in producer.SPLITS}, rules['pools'])
            registry = list(producer.read_jsonl(root / 'pools/metadata/generation/documents.jsonl'))
            self.assertTrue(registry and all(d['external'] == 1 for d in registry))
            self.assertEqual(file_hash(root / 'lm/manifest.json'), original_pin)
            for s in producer.SPLITS:
                rows = list(producer.read_jsonl(root / f'pools/{s}.jsonl'))
                self.assertTrue(all('teacher_scores' not in r and 'reference_indices' not in r for r in rows))
            db.close()
            # Existing cache loader and trainer must accept the new independent registry.
            cache_teacher(root / 'pretrain.json', root / 'lm', root / 'pools', root / 'teacher', SyntheticTeacher())
            self.assertTrue((root / 'teacher/metadata/generation/documents.jsonl').is_file())
            model = CharacterLM(config['model'], tokenizer.active_ids)
            atomic_checkpoint(root / 'parent.pt', dict(schema_version=1, kind='si-character-lm', stage='pretrain',
                config=config, tokenizer=tokenizer.to_dict(), tokenizer_digest=tokenizer.digest, dataset_id=manifest['dataset_id'],
                model=model.state_dict(), step=0, code_identity='authored-synthetic-fixture'))
            config['stage'] = 'distill'
            write_json(root / 'distill.json', config)
            result = train(root / 'distill.json', root / 'lm', root / 'run', 'cpu',
                           pools_path=root / 'teacher', init_checkpoint=root / 'parent.pt', threads=1)
            self.assertEqual(result['step'], 1)
            binary = producer.REPO / 'target/release/si-cli'
            if binary.exists():
                # Exercise the actual producer entry point, exported reading table,
                # persistent Rust process, scratch index and atomic publication.
                (root / 'words.csv').write_text('text,reading,weight\n' + ''.join(
                    f'{c},shi,10\n' for c in sorted(set(alphabet)) if producer.HAN.fullmatch(c)), encoding='utf-8')
                subprocess.run([str(binary), 'lexicon', 'build', str(root / 'base.silex'), '0', str(root / 'words.csv')],
                               check=True, capture_output=True)
                (root / 'corpus.txt').write_text('登录 系统\n', encoding='utf-8')
                subprocess.run([str(binary), 'corpus', 'build', str(root / 'base.silex'), str(root / 'base.sigram'),
                                str(root / 'corpus.txt')], check=True, capture_output=True)
                args = ['producer', '--sources', str(root / 'sources.json'), '--sampling', str(root / 'sampling.json'),
                        '--si-root', str(raw), '--data', str(root / 'lm'), '--config', str(root / 'distill.json'),
                        '--binary', str(binary), '--lexicon', str(root / 'base.silex'), '--grams', str(root / 'base.sigram'),
                        '--output', str(root / 'cli-pools')]
                with patch('sys.argv', args):
                    producer.main()
                cli_manifest, _ = load_pools(root / 'cli-pools', config, manifest, tokenizer, ('train',), scored=False)
                self.assertEqual(cli_manifest['splits']['train']['pools'], 12)
                self.assertEqual(cli_manifest['limits']['candidate_tokens'], 16)
                blocked = root / '.blocked.work'
                blocked.mkdir()
                write_json(blocked / 'identity.json', read_json(root / '.cli-pools.work/identity.json'))
                with (blocked / 'writer.lock').open('a') as stream:
                    producer.fcntl.flock(stream, producer.fcntl.LOCK_EX | producer.fcntl.LOCK_NB)
                    with patch('sys.argv', [*args[:-1], str(root / 'blocked'), '--resume']):
                        with self.assertRaisesRegex(ValueError, 'Another generator'):
                            producer.main()


if __name__ == '__main__':
    unittest.main()
