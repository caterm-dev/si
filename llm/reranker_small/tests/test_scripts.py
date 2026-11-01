import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from llm.reranker_small.fixtures import fixture
from llm.reranker_small.settings import ROOT


class ScriptTests(unittest.TestCase):
    def environment(self, **overrides):
        result = {key: value for key, value in os.environ.items() if not key.startswith('SI_RERANKER_SMALL_')}
        result['SI_RERANKER_SMALL_PYTHON'] = sys.executable
        result.update(overrides)
        return result

    def execute(self, name, cwd, env, *args):
        return subprocess.run([str(ROOT / 'scripts' / (name + '.sh')), *map(str, args)], cwd=cwd,
                              env=env, text=True, capture_output=True, timeout=90)

    def test_independent_stage_dispatch_ignores_converter_overrides(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recorder = root / 'record-python'
            recorder.write_text(f'#!{sys.executable}\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            recorder.chmod(0o755)
            env = self.environment(SI_RERANKER_SMALL_PYTHON=str(recorder),
                                   SI_LLM_CONFIG='/must-not-be-used/config.json',
                                   SI_LLM_RUN='/must-not-be-used/run')
            modules = {'data': 'prepare', 'run': 'train', 'resume': 'train', 'validation': 'evaluate',
                       'test': 'evaluate', 'evaluate': 'benchmark', 'rank': 'rank', 'export': 'export', 'size': 'model'}
            for script, module in modules.items():
                result = self.execute(script, root, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(result.stdout)
                self.assertEqual(args[:2], ['-m', 'llm.reranker_small.' + module])
                self.assertNotIn('/must-not-be-used/run', args)
                if '--config' in args:
                    self.assertEqual(args[args.index('--config') + 1], str(ROOT / 'configs/small.json'))
            self.assertEqual(list(root.iterdir()), [recorder])

    def test_terminal_stages_from_other_cwd_and_exact_literal_preservation(self):
        with tempfile.TemporaryDirectory(prefix='si reranker stages ') as temporary:
            root = Path(temporary)
            config, lock, raw = fixture(root / 'fixture')
            env = self.environment(SI_RERANKER_SMALL_CONFIG=str(config),
                                   SI_RERANKER_SMALL_DATA=str(root / 'data'),
                                   SI_RERANKER_SMALL_RUN=str(root / 'run'),
                                   SI_RERANKER_SMALL_REPORT_ROOT=str(root / 'reports'),
                                   SI_RERANKER_SMALL_EXPORT=str(root / 'export'),
                                   SI_RERANKER_SMALL_DEVICE='cpu', SI_RERANKER_SMALL_THREADS='2')
            def run(name, *args):
                result = self.execute(name, root, env, *args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result
            run('data', '--source-lock', lock, '--raw-root', raw)
            self.assertFalse((root / 'run').exists())
            run('run', '--max-steps', '1')
            self.assertFalse((root / 'reports').exists())
            self.assertFalse((root / 'export').exists())
            run('resume', '--max-steps', '2')
            run('validation', '--max-tokens', '64')
            self.assertFalse((root / 'reports/test.json').exists())
            run('test', '--max-tokens', '64')
            run('export')
            literal = "Foo'$(touch SHOULD_NOT_EXIST)`echo unsafe`𠮷"
            result = run('rank', '--checkpoint', root / 'export/model.pt', '--context', '今天，',
                         '--candidate', '中文测试', '--candidate', '中文侧试', '--input', literal)
            self.assertEqual(json.loads(result.stdout)['candidates'][-1], literal)
            self.assertFalse((root / 'SHOULD_NOT_EXIST').exists())
            result = run('rank', '--input', '', '--candidate', '中文测试')
            self.assertEqual(json.loads(result.stdout)['candidates'], [])
            existing = root / 'keep directory'
            existing.mkdir()
            (existing / 'sentinel').write_text('keep')
            result = self.execute('setup', root, env, '--python', sys.executable, '--venv', existing)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((existing / 'sentinel').read_text(), 'keep')
