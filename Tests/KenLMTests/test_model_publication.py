"""Retained model publication survives build cleanup and never promotes bad bytes."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import install_kenlm_model as delivery


class ModelPublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.build = self.root / '.build/run/final'
        self.build.mkdir(parents=True)
        self.binary = self.build / 'final.bin'
        self.binary.write_bytes(b'synthetic trained model')
        self.metadata = self.build / 'final.meta.json'
        self.data = {'schema_version': 1, 'kenlm': {'binary_format_version': 5},
                     'corpus': {'source_order': ['train', 'heldout']},
                     'functional_sanity_passed': True,
                     'cleaning': {'version': 'si-kenlm-cleaning-v1', 'unicode_version': '15.0.0',
                                  'maximum_scalars': 32, 'rare_threshold_exclusive': 5,
                                  'module_sha256': hashlib.sha256((ROOT / 'scripts/kenlm_cleaning.py').read_bytes()).hexdigest(),
                                  'vectors_sha256': hashlib.sha256((ROOT / 'Tests/KenLMTests/cleaning_vectors.json').read_bytes()).hexdigest()},
                     'model': {'order': 4, 'a': 22, 'prune': [0, 0, 1, 2], 'probability_bits': 8,
                               'backoff_bits': 8, 'binary_sha256': hashlib.sha256(self.binary.read_bytes()).hexdigest(),
                               'binary_bytes': self.binary.stat().st_size}}
        self.metadata.write_text(json.dumps(self.data))
        self.store = self.root / 'corpus/kenlm/models'

    def test_publication_survives_build_cleanup_and_preserves_reference(self):
        sanity = self.build / 'sanity'
        sanity.mkdir()
        (sanity / 'native-reference.json').write_text(json.dumps({'model_sha256': self.data['model']['binary_sha256']}))
        (self.build.parent / 'input-code-pin.json').write_text('{"synthetic-code-sha256":"example"}\n')
        current = delivery.publish(self.binary, self.metadata, self.store)
        self.assertTrue(current.is_symlink())
        self.assertEqual(current.readlink(), Path(self.data['model']['binary_sha256']))
        shutil.rmtree(self.root / '.build')
        self.assertEqual(delivery.verify_model(current / 'final.bin', current / 'final.meta.json'), self.data)
        self.assertEqual((current / 'final.bin').read_bytes(), b'synthetic trained model')
        self.assertTrue((current / 'native-reference.json').is_file())
        self.assertEqual((current / 'provenance/input-code-pin.json').read_text(),
                         '{"synthetic-code-sha256":"example"}\n')

    def test_corrupt_input_or_failed_sanity_preserves_current_version(self):
        current = delivery.publish(self.binary, self.metadata, self.store)
        before = current.readlink()
        self.binary.write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum or size'):
            delivery.publish(self.binary, self.metadata, self.store)
        self.assertEqual(current.readlink(), before)
        self.assertEqual((current / 'final.bin').read_bytes(), b'synthetic trained model')
        self.data['functional_sanity_passed'] = False
        self.metadata.write_text(json.dumps(self.data))
        with self.assertRaisesRegex(ValueError, 'sanity-validated'):
            delivery.publish(self.binary, self.metadata, self.store)
        self.assertEqual(current.readlink(), before)

    def test_missing_inputs_have_actionable_cli_error(self):
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/install_kenlm_model.py'),
                                 '--verify-only', '--model', str(self.root / 'missing.bin'),
                                 '--metadata', str(self.root / 'missing.json')], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing trained KenLM artifact', result.stderr)
        self.assertIn('app build does not recreate', result.stderr)
        self.assertNotIn('Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
