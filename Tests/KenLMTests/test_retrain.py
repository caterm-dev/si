"""New count-dictionary snapshots and leakage-free KenLM preparation."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import retrain_kenlm as retrain


class RetrainTests(unittest.TestCase):
    def test_dictionary_snapshot_rejects_intervening_vocabulary_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'Data/Chinese'
            source.mkdir(parents=True)
            csv = source / 'base.csv'
            csv.write_text('text,reading,weight\n词,ci,100\n')
            run = root / 'run'
            run.mkdir()
            with patch.object(retrain, 'ROOT', root):
                retrain.snapshot(run, 'Chinese', run / 'dictionary')
                retrain.snapshot(run, 'Chinese', run / 'dictionary')
                csv.write_text('text,reading,weight\n词,ci,101\n')
                with self.assertRaisesRegex(ValueError, 'Current vocabulary differs'):
                    retrain.snapshot(run, 'Chinese', run / 'dictionary')
                self.assertIn(',100', (run / 'dictionary/base.csv').read_text())

    def test_selection_rare_mapping_uses_train_counts_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / 'data'
            data.mkdir()
            (data / 'train.txt').write_text('少见 字典 1\n' * 4)
            (data / 'heldout.txt').write_text('少见 字典 2\n' * 10)
            output = root / 'clean'
            stats = retrain.clean_selection(data, output, {'字典'})
            self.assertEqual((output / 'train.txt').read_text(), '<oov> 字典 <num>\n' * 4)
            self.assertEqual((output / 'heldout.txt').read_text(), '<oov> 字典 <num>\n' * 10)
            self.assertEqual(stats['train']['rare'], 4)
            self.assertEqual(stats['heldout']['rare'], 10)
            self.assertEqual(retrain.clean_selection(data, output, {'字典'}), stats)
            (output / 'heldout.txt').write_text('tampered\n')
            with self.assertRaisesRegex(ValueError, 'Cleaned split changed'):
                retrain.clean_selection(data, output, {'字典'})

    def test_final_full_fit_uses_explicit_inputs_and_recalculates_full_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / 'data'
            data.mkdir()
            inputs = (data / 'train.txt', data / 'heldout.txt')
            inputs[0].write_text('少见 字典 1\n' * 4)
            inputs[1].write_text('少见 字典 2\n' * 2)
            split = {name: {'sha256': retrain.training.digest(path), 'lines': lines, 'tokens': 3 * lines}
                     for name, path, lines in zip(('train', 'heldout'), inputs, (4, 2))}
            output = root / 'final'
            output.mkdir()
            result = retrain.final.prepare(output, inputs=inputs, dictionary={'字典'}, split_manifest=split)
            self.assertEqual((output / 'full.clean2.txt').read_text(), '少见 字典 <num>\n' * 6)
            self.assertEqual(result['cleaned']['lines'], 6)
            self.assertEqual(result['source_order'], ['train', 'heldout'])
            self.assertFalse(result['new_splitting'])


if __name__ == '__main__':
    unittest.main()
