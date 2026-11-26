"""Only small authored raw-text-v2 snapshots; never read real corpus files."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from llm.pinyin_to_text.common import normalized, read_jsonl
from llm.reranker_small.data import load_bundle
from llm.reranker_large.corpus_data import BUNDLES, Snapshot, assigned_split, prepare_corpus
from llm.reranker_large.settings import ROOT, file_hash, fingerprint, load_config, read_json, write_json


def save_snapshot(root, name, source, rows):
    path = root / name
    path.mkdir(parents=True, exist_ok=True)
    metadata, texts, next_line = [], [], 1
    for meta, text in rows:
        lines = text.splitlines(keepends=True)
        metadata.append({**meta, 'first_line': next_line, 'lines': len(lines)})
        texts.extend(lines)
        next_line += len(lines)
    (path / 'text.txt').write_text(''.join(texts), encoding='utf-8')
    (path / 'documents.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in metadata))
    files = {str(p.relative_to(path)): dict(bytes=p.stat().st_size, sha256=file_hash(p))
             for p in sorted(path.rglob('*')) if p.is_file() and p.name != 'manifest.json'}
    write_json(path / 'manifest.json', dict(schema_version=2,
        extraction_contract='complete-simplified-text-lines-v2', source=source,
        files=files, counts=dict(documents=len(rows))))


def fixture(root):
    root = Path(root)
    prepared, notices = root / 'raw-text-v2', root / 'notices'
    notices.mkdir(parents=True)
    mixture = dict(schema_version=1, train_target_tokens=300, calibration_characters=2000,
                   validation_fraction=.2, test_fraction=.2,
                   shares=dict(dialogue=.6, wikipedia=.35, technical=.05))
    write_json(root / 'mixture.json', mixture)
    write_json(root / 'config.json', read_json(ROOT / 'configs/smoke.json'))
    for name in BUNDLES:
        path = prepared / name
        path.mkdir(parents=True)
        rows = []
        if name == 'dialogue':
            datasets = []
            for dataset in ('kdconv', 'crosswoz'):
                notice = path / f'attribution/licenses/{dataset}.txt'
                notice.parent.mkdir(parents=True, exist_ok=True)
                notice.write_text('SI-authored synthetic regression data; GPL-3.0-only.\n')
                datasets.append(dict(id=dataset, repository='fixture://' + dataset, revision='fixture-v1',
                    license='GPL-3.0-only', documents=[dict(path=f'licenses/{dataset}.txt', sha256=file_hash(notice))]))
                for split in ('train', 'dev', 'test'):
                    for group in range(3):
                        for turn in range(2):
                            meta = dict(origin=f'{dataset}/{split}/{group}/turn:{turn}', dataset=dataset,
                                        path=f'{dataset}/{split}.json', split=split, conversation=group, turn=turn)
                            text = f'{dataset} 会话{group} {split} 发言{turn}。Alpha_ID 123。\n'
                            rows.append((meta, text))
            # This same-directory LCCC copy and multilingual OASST must be skipped.
            for identity in ('lccc-base', 'oasst1', 'english-only'):
                rows.append((dict(origin=identity, dataset=identity), f'Excluded {identity} English material.\n'))
            source = dict(id=name, kind=name, datasets=datasets)
        else:
            notice = notices / f'licenses/{name}.txt'
            notice.parent.mkdir(parents=True, exist_ok=True)
            notice.write_text('SI-authored synthetic regression data; GPL-3.0-only.\n')
            source = dict(id=name, kind=name, repository='fixture://' + name, revision='fixture-v1',
                          license='GPL-3.0-only', license_document=dict(path=f'licenses/{name}.txt', sha256=file_hash(notice)))
            counts = {s: 0 for s in ('train', 'validation', 'test')}
            index = 0
            while min(counts.values()) < 4:
                group = (f'row:{index}' if name == 'lccc' else
                         f'https://fixture.invalid/wiki?curid={index}' if name == 'wikipedia' else f'{name}/page-{index}.md')
                split = assigned_split(42, name, group, mixture)
                index += 1
                if counts[split] >= 4:
                    continue
                counts[split] += 1
                rare = '龘' if split != 'train' else ''
                for turn in range(2 if name == 'lccc' else 1):
                    origin = (f'{group}/turn:{turn}' if name == 'lccc' else
                              group + '&oldid=8' if name == 'wikipedia' else group)
                    rows.append((dict(origin=origin), f'{name} 样本{group} 发言{turn} 中文与 Alpha_ID。{rare}\n'))
        save_snapshot(prepared, name, source, rows)
    return root / 'config.json', root / 'mixture.json', prepared, notices


class CorpusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='si-corpus-adapter-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config, self.mixture, self.prepared, self.notices = fixture(self.root / 'input')

    def run_prepare(self, name='output', **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return prepare_corpus(self.config, self.mixture, self.prepared, self.notices, self.root / name, **kwargs)

    def test_complete_bundle_is_deterministic_and_reports_actual_tokens(self):
        first = self.run_prepare()
        second = self.run_prepare('second')
        self.assertEqual(first['dataset_id'], second['dataset_id'])
        manifest, tokenizer, _ = load_bundle(self.root / 'output', load_config(self.config), ('train', 'validation', 'test'))
        self.assertNotIn('manifest.json', manifest['files'])
        for name, expected in manifest['files'].items():
            self.assertEqual(file_hash(self.root / 'output' / name), expected, name)
        self.assertNotIn('龘', tokenizer.lookup)
        report = read_json(self.root / 'output/sampling-report.json')
        for split in ('train', 'validation', 'test'):
            actual = report['actual'][split]
            self.assertEqual(actual['targets'], manifest['splits'][split]['targets'])
            self.assertAlmostEqual(sum(actual['shares'].values()), 1.)
        self.assertGreater(manifest['splits']['validation']['byte_fallback_scalars'], 0)
        self.assertEqual(report['counts']['excluded_lccc-base_turns'], 1)
        self.assertEqual(report['counts']['excluded_oasst1_turns'], 1)
        self.assertTrue((self.root / 'output/metadata/attribution/wikipedia/input-manifest.json').is_file())
        self.assertTrue((self.root / 'output/metadata/attribution/dialogue/licenses/kdconv.txt').is_file())
        rows = list(read_jsonl(self.root / 'output/import/documents.jsonl'))
        for row in rows:
            self.assertIn(row['source'], ('lccc', 'kdconv', 'crosswoz', 'wikipedia', 'kubernetes', 'tensorflow', 'mdn'))
            if row['source'] in ('lccc', 'kdconv', 'crosswoz'):
                self.assertIn('发言0', row['text'])
                self.assertIn('发言1', row['text'])
            if row['upstream_split'] is not None:
                self.assertEqual(row['split'], row['upstream_split'])
            self.assertIn('Alpha_ID', row['text'])
        with self.assertRaises(FileExistsError):
            self.run_prepare()

    def test_changed_text_checksum_fails_atomically(self):
        path = self.prepared / 'wikipedia/text.txt'
        data = path.read_bytes()
        path.write_bytes(b'X' + data[1:])
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.run_prepare()
        self.assertFalse((self.root / 'output').exists())

    def test_complete_dialogue_override_preserves_verification_and_input_files(self):
        good = self.root / 'complete-dialogue'
        shutil.copytree(self.prepared / 'dialogue', good)
        damaged = self.prepared / 'dialogue/text.txt'
        damaged.write_text('Manually pruned text without updated metadata.\n')
        pin = file_hash(damaged)
        with self.assertRaisesRegex(ValueError, 'declared.*actual.*--dialogue-root'):
            self.run_prepare()
        self.assertFalse((self.root / 'output').exists())
        result = self.run_prepare(dialogue_root=good)
        expected = file_hash(good / 'manifest.json')
        self.assertEqual(result['corpus_sampling']['prepared_manifest_hashes']['dialogue'], expected)
        self.assertEqual(file_hash(damaged), pin)
        changed = good / 'text.txt'
        content = changed.read_bytes()
        changed.write_bytes(b'X' + content[1:])
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.run_prepare('bad-override', dialogue_root=good)
        self.assertFalse((self.root / 'bad-override').exists())

    def test_bad_text_range_and_notice_checksum_are_rejected(self):
        path = self.prepared / 'lccc/documents.jsonl'
        rows = list(read_jsonl(path))
        rows[0]['first_line'] = 2
        path.write_text(''.join(json.dumps(r) + '\n' for r in rows))
        m = read_json(path.parent / 'manifest.json')
        m['files']['documents.jsonl'] = dict(bytes=path.stat().st_size, sha256=file_hash(path))
        write_json(path.parent / 'manifest.json', m)
        with self.assertRaisesRegex(ValueError, 'document range'):
            self.run_prepare()
        self.assertFalse((self.root / 'output').exists())
        # A second fresh snapshot exercises retained attribution validation.
        config, mixture, prepared, notices = fixture(self.root / 'other')
        (notices / 'licenses/wikipedia.txt').write_text('changed license bytes')
        with self.assertRaisesRegex(ValueError, 'notice checksum'):
            prepare_corpus(config, mixture, prepared, notices, self.root / 'bad-notice')
        self.assertFalse((self.root / 'bad-notice').exists())

    def test_shortfalls_require_an_explicit_option(self):
        with self.assertRaisesRegex(ValueError, 'Insufficient'):
            self.run_prepare(train_tokens=100000000)
        self.assertFalse((self.root / 'output').exists())
        self.run_prepare(allow_shortfall=True, train_tokens=100000000)
        report = read_json(self.root / 'output/sampling-report.json')
        self.assertGreater(report['selection']['train']['wikipedia']['shortfall'], 0)

    def test_long_utf8_line_is_streamed_and_oversized_groups_are_flagged(self):
        path = self.prepared / 'wikipedia'
        source = read_json(path / 'manifest.json')['source']
        long_text = '中' * 30000 + 'Alpha_ID\n'
        save_snapshot(self.prepared, 'wikipedia', source,
                      [(dict(origin='https://fixture.invalid/wiki?curid=900&oldid=8'), long_text)])
        snapshot = Snapshot(self.prepared, 'wikipedia', self.notices, self.root / 'audit')
        rows = list(snapshot.rows(100000))
        self.assertEqual(rows[0][1], long_text)
        self.assertFalse(rows[0][2])
        rows = list(snapshot.rows(100))
        self.assertIsNone(rows[0][1])
        self.assertTrue(rows[0][2])

    def test_reappearing_page_group_is_not_silently_merged(self):
        path = self.prepared / 'wikipedia'
        source = read_json(path / 'manifest.json')['source']
        metadata = list(read_jsonl(path / 'documents.jsonl'))
        texts = (path / 'text.txt').read_text().splitlines(keepends=True)
        rows = [(dict(origin=m['origin']), text) for m, text in zip(metadata, texts, strict=True)]
        rows.append((dict(origin=metadata[0]['origin']), 'A different final page body.\n'))
        save_snapshot(self.prepared, 'wikipedia', source, rows)
        with self.assertRaisesRegex(ValueError, 'noncontiguously'):
            self.run_prepare()
        self.assertFalse((self.root / 'output').exists())

    def test_cross_split_paragraph_overlap_excludes_a_whole_group(self):
        path = self.prepared / 'lccc'
        source = read_json(path / 'manifest.json')['source']
        metadata = list(read_jsonl(path / 'documents.jsonl'))
        texts = (path / 'text.txt').read_text().splitlines(keepends=True)
        shared = 'This authored shared paragraph exceeds thirty two characters.\n'
        # Two different conversations keep distinct complete text, but share a paragraph.
        chosen = {}
        mixture = read_json(self.mixture)
        for index, row in enumerate(metadata):
            group = row['origin'].split('/turn:')[0]
            split = assigned_split(42, 'lccc', group, mixture)
            if split in ('train', 'test') and split not in chosen:
                chosen[split] = index
        train_group = metadata[chosen['train']]['origin'].split('/turn:')[0]
        for index in chosen.values():
            texts[index] += shared
        save_snapshot(self.prepared, 'lccc', source,
                      [(dict(origin=m['origin']), text) for m, text in zip(metadata, texts, strict=True)])
        self.run_prepare(train_tokens=100000000, allow_shortfall=True)
        selected = list(read_jsonl(self.root / 'output/import/documents.jsonl'))
        self.assertFalse(any(r['source'] == 'lccc' and r['group'] == train_group for r in selected))
        report = read_json(self.root / 'output/sampling-report.json')
        self.assertGreater(report['counts']['train_cross_split_paragraph_groups_excluded'], 0)

    def test_heldout_exact_duplicates_remove_training_copies(self):
        # Copy a held-out dialogue's complete two-turn text into one LCCC train group.
        path = self.prepared / 'lccc'
        rows = list(read_jsonl(path / 'documents.jsonl'))
        texts = (path / 'text.txt').read_text().splitlines(keepends=True)
        dialogue_meta = list(read_jsonl(self.prepared / 'dialogue/documents.jsonl'))
        dialogue_text = (self.prepared / 'dialogue/text.txt').read_text().splitlines(keepends=True)
        test_index = next(i for i, r in enumerate(dialogue_meta) if r.get('dataset') == 'kdconv' and r.get('split') == 'test')
        group_index = next(i for i, r in enumerate(rows) if assigned_split(42, 'lccc', r['origin'].split('/turn:')[0],
                                                                          read_json(self.mixture)) == 'train')
        texts[group_index:group_index + 2] = dialogue_text[test_index:test_index + 2]
        altered = [(dict(origin=r['origin']), text) for r, text in zip(rows, texts, strict=True)]
        save_snapshot(self.prepared, 'lccc', read_json(path / 'manifest.json')['source'], altered)
        self.run_prepare(train_tokens=100000000, allow_shortfall=True)
        all_rows = list(read_jsonl(self.root / 'output/import/documents.jsonl'))
        identity = fingerprint(normalized(''.join(dialogue_text[test_index:test_index + 2])))
        copies = [r for r in all_rows if fingerprint(normalized(r['text'])) == identity]
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0]['split'], 'test')

    def test_cli_reads_only_explicit_synthetic_roots_and_does_not_train(self):
        command = [str(ROOT / 'scripts/prepare-data.sh'), '--config', str(self.config),
                   '--mixture-config', str(self.mixture), '--prepared-root', str(self.prepared),
                   '--dialogue-root', str(self.prepared / 'dialogue'),
                   '--notices-root', str(self.notices), '--output', str(self.root / 'cli-output')]
        env = {**os.environ, 'SI_RERANKER_LARGE_PYTHON': sys.executable}
        result = subprocess.run(command, cwd='/tmp', env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'cli-output/train.tokens.bin').is_file())
        self.assertFalse(list((self.root / 'cli-output').rglob('*.pt')))


if __name__ == '__main__':
    unittest.main()
