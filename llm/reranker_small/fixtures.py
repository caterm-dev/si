"""Tiny SI-authored public fixtures, used only by explicit smoke/tests."""

import io
from pathlib import Path
import tarfile

from .settings import ROOT, file_hash, read_json, write_json


def fixture(root):
    root = Path(root)
    source = root / 'source'
    (source / 'licenses').mkdir(parents=True)
    notice = source / 'licenses/fixture.txt'
    notice.write_text('SI-authored synthetic regression material. GPL-3.0-only.\n', encoding='utf-8')
    archive = root / 'raw/fixture/source.tar.gz'
    archive.parent.mkdir(parents=True)
    with tarfile.open(archive, 'w:gz') as handle:
        for index in range(80):
            text = (f'# 合成文档 {index}\n\n今天讨论中文输入模型第{index}组，保留标点与 English words。\n\n'
                    f'这是编号{index}的另一段测试文字，用来验证文档边界、候选评分和稳定续训。\n')
            content = text.encode()
            member = tarfile.TarInfo(f'fixture/zh/{index}.md')
            member.size = len(content)
            handle.addfile(member, io.BytesIO(content))
    write_json(source / 'sources.lock.json', {
        'schema_version': 1, 'language': 'zh-Hans', 'sources': [{
            'id': 'fixture', 'kind': 'markdown', 'revision': 'a' * 40, 'prefix': 'zh/',
            'path': 'source.tar.gz', 'size': archive.stat().st_size, 'sha256': file_hash(archive),
            'origin': 'SI-authored synthetic workflow fixture', 'license': 'GPL-3.0-only',
            'license_document': {'path': 'licenses/fixture.txt', 'sha256': file_hash(notice)},
        }],
    })
    config = read_json(ROOT / 'configs/smoke.json')
    write_json(root / 'config.json', config)
    return root / 'config.json', source / 'sources.lock.json', root / 'raw'
