"""Small SI-authored synthetic inputs; never discover corpora or load Qwen."""

from pathlib import Path

from llm.pinyin_to_text.common import normalized, write_jsonl
from .settings import ROOT, fingerprint, read_json, write_json


class SyntheticTeacher:
    identity = {'model_id': 'si-synthetic-workflow-fixture', 'protocol': 'fixture-only-v1'}

    def __init__(self):
        self.calls = []

    def score(self, row):
        self.calls.append(row['split'])
        preferred = '登陆' if '账号' in row['context'] else ('开会' if row['input'] == 'kaihui' else '登录')
        return [-1.0 if c['text'] == preferred else -4.0 for c in row['candidates']]

    def verify(self):
        pass


def fixture(root):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    config = read_json(ROOT / 'configs/smoke.json')
    pretrain, distill = root / 'pretrain.json', root / 'distill.json'
    write_json(pretrain, config)
    config['stage'] = 'distill'
    write_json(distill, config)
    provenance = root / 'provenance.json'
    write_json(provenance, dict(schema_version=1, sources=[dict(id='fixture',
        origin='SI-authored synthetic regression inputs, not actual typing or independent annotation',
        revision='fixture-v1', license='GPL-3.0-only')]))
    definitions = {
        'train': ('今天需要', '登录', '明天需要'),
        'validation': ('账号需要', '登陆', '稍后需要'),
        'test': ('项目需要', '登录', '大家需要'),
    }
    documents, pools = [], []
    for split, (context, observed, meeting) in definitions.items():
        text = f'{context}{observed}。{meeting}开会。English {split}.'
        document = dict(source='fixture', origin=split, group=split, split=split, text=text)
        documents.append(document)
        identity = fingerprint(normalized(text))
        for index, (history, target, spelling, candidates) in enumerate([
            (context, observed, 'denglu', [('登录', 'zh-Hans'), ('登陆', 'zh-Hans'), ('登录', 'mixed')]),
            (meeting, '开会', 'kaihui', [('开会', 'zh-Hans'), ('开慧', 'zh-Hans')])]):
            pools.append(dict(id=f'{split}-{index}', document_id=identity, context=history,
                observed_text=target, input=spelling, candidates=[dict(text=t, language=l) for t, l in candidates],
                reference_indices=[i for i, (t, _) in enumerate(candidates) if t == target], labels_reviewed=True))
    write_jsonl(root / 'documents.jsonl', documents)
    write_jsonl(root / 'pools.jsonl', pools)
    return pretrain, distill, provenance, root / 'documents.jsonl', root / 'pools.jsonl'
