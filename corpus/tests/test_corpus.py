"""Synthetic regression cases; no personal text or network is used."""

import gzip
import bz2
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from collections import Counter

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from opencc import OpenCC
from clean.chinese import markdown_text, segments, web_prose
from clean.wikipedia import remove_nested, wikitext
from common import digest, new_directory, verified_archive
from prepare import documents, prepare_source
from check import check
from wikipedia import INDEX, download, download_ranges, refresh, resolve_latest, verify


class ChineseCorpusTests(unittest.TestCase):
    def setUp(self):
        self.converter = OpenCC('t2s')

    def test_boundaries_and_simplification(self):
        text = '我們準備好了，開始中文測試 Python 程式正常運作。今天下午開會\n明天上午出發'
        self.assertEqual(list(segments(text, self.converter)),
                         ['我们准备好了', '开始中文测试', '程式正常运作', '今天下午开会', '明天上午出发'])

    def test_frozen_bundle_survives_source_lock_updates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'licenses').mkdir()
            notice = root / 'licenses/license.txt'
            notice.write_text('Synthetic fixture license\n')
            source = {'id': 'fixture', 'kind': 'lccc', 'revision': 'a' * 40,
                      'path': 'fixture.gz', 'size': 1, 'sha256': 'b' * 64, 'license': 'fixture',
                      'license_document': {'path': 'licenses/license.txt', 'sha256': digest(notice)}}
            lock = root / 'sources.lock.json'
            lock.write_text(json.dumps({'schema_version': 1, 'language': 'zh-Hans', 'sources': [source]}))
            archive = root / 'input.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps(['中文测试内容']) + '\n')
            result = prepare_source(source, archive, root / 'fixture', self.converter, 0)
            (root / 'manifest.json').write_text(json.dumps({
                'source_lock_sha256': digest(lock), 'sources': [result]}))
            with patch('common.LOCK', root / 'nonexistent-current-lock.json'):
                self.assertEqual(check(root)['total_characters'], 6)

    def test_limits_and_supplementary_han(self):
        self.assertEqual(list(segments('中文，中文测试，𠮷𠮷𠮷𠮷，' + '汉' * 100, self.converter)),
                         ['中文测试', '𠮷𠮷𠮷𠮷', '汉' * 96, '汉' * 4])

    def test_documentation_code_and_metadata_are_excluded(self):
        text = ('---\ntitle: 不要保留元数据\n---\n正常正文内容\n'
                '```python\n不要保留代码内容\n```\n'
                '~~~text\n也不要保留代码内容\n~~~\n'
                '<!--不要保留注释内容-->\n<pre>不要保留代码内容</pre>\n'
                '[保留链接文字](https://example.invalid)\n'
                '{{< shortcode 不要保留模板内容 >}}\n'
                '| 不要保留表格内容 |\n`不要保留行内代码`\n最后正文内容')
        self.assertEqual(list(segments(markdown_text(text), self.converter)),
                         ['正常正文内容', '保留链接文字', '最后正文内容'])

    def test_unclosed_code_fence_does_not_leak_code(self):
        text = '正常正文内容\n```python\n不要保留代码内容'
        self.assertEqual(list(segments(markdown_text(text), self.converter)), ['正常正文内容'])

    def test_web_prose_filter(self):
        self.assertFalse(web_prose('导航 标题'))
        self.assertFalse(web_prose('python ' * 80))
        self.assertTrue(web_prose('这是用于测试的中文正文内容。' * 8))

    def test_wikitext_removes_nested_markup_and_keeps_readable_links(self):
        raw = ('正常正文内容{{模板|嵌套={{内部模板|不要保留}}}}另外正文内容\n'
               '{| class="wikitable"\n|不要保留表格\n{|\n|嵌套表格\n|}\n|}\n'
               '[[北京|北京城市介绍]]位于中国北方。\n'
               '[[File:测试图片.jpg|缩略图|[[不要保留图片描述]]]]\n'
               '<ref name="a">不要保留引文</ref>保留引用后文<ref name="a"/>\n'
               '<syntaxhighlight lang="py">不要保留代码</syntaxhighlight>\n'
               '[[Category:不要保留分类]]\n[https://example.invalid 保留外链描述]\n'
               '<!--不要保留注释-->最后正文内容')
        cleaned = wikitext(raw)
        self.assertEqual(list(segments(cleaned, self.converter)),
                         ['正常正文内容', '另外正文内容', '北京城市介绍位于中国北方',
                          '保留引用后文', '保留外链描述', '最后正文内容'])
        self.assertEqual(remove_nested('正文{{未闭合模板', '{{', '}}'), '正文 ')

    def test_wikipedia_streams_only_current_articles_with_exact_origins(self):
        xml = ('<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/">'
               '<page><title>测试</title><ns>0</ns><id>1</id><revision><id>11</id>'
               '<model>wikitext</model><text>這是中文百科正文</text></revision></page>'
               '<page><ns>0</ns><id>2</id><redirect title="测试"/>'
               '<revision><id>12</id><text>不要保留重定向</text></revision></page>'
               '<page><ns>10</ns><id>3</id><revision><id>13</id>'
               '<text>不要保留模板内容</text></revision></page>'
               '<page><ns>0</ns><id>4</id><revision><id>14</id>'
               '<text>另外中文百科正文</text></revision></page></mediawiki>')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'wiki.xml.bz2'
            path.write_bytes(bz2.compress(xml.encode()))
            counts = Counter()
            result = list(documents({'kind': 'wikipedia'}, path, counts))
            self.assertEqual([origin for origin, _ in result], [
                'https://zh.wikipedia.org/w/index.php?curid=1&oldid=11',
                'https://zh.wikipedia.org/w/index.php?curid=4&oldid=14'])
            self.assertEqual([list(segments(text, self.converter)) for _, text in result],
                             [['这是中文百科正文'], ['另外中文百科正文']])
            self.assertEqual(counts['records_read'], 4)
            self.assertEqual(counts['redirect_pages'], 1)
            self.assertEqual(counts['nonarticle_pages'], 1)

    def test_wikipedia_official_checksum_rejects_same_size_corruption(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'wiki.bz2'
            path.write_bytes(b'original')
            source = {'size': 8, 'sha1': hashlib.sha1(b'original').hexdigest()}
            self.assertEqual(verify(path, source), digest(path))
            path.write_bytes(b'modified')
            with self.assertRaises(ValueError):
                verify(path, source)

    def test_wikipedia_resume_ignoring_range_restarts_instead_of_appending(self):
        import hashlib
        payload = b'full archive'
        class Response(io.BytesIO):
            status = 200
            headers = {}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'wikipedia'
            directory.mkdir()
            (directory / 'wiki.bz2.part').write_bytes(b'full ')
            source = {'id': 'wikipedia', 'path': 'wiki.bz2', 'url': 'https://example.invalid/archive',
                      'size': len(payload), 'sha1': hashlib.sha1(payload).hexdigest()}
            with patch('wikipedia.urllib.request.urlopen', return_value=Response(payload)):
                download(source, root)
            self.assertEqual((directory / 'wiki.bz2').read_bytes(), payload)

    def test_wikipedia_resume_validates_exact_range_before_writing(self):
        import hashlib
        payload = b'full archive'
        class Response(io.BytesIO):
            status = 206
            headers = {'Content-Range': f'bytes 5-{len(payload) - 1}/{len(payload)}'}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'wikipedia'
            directory.mkdir()
            partial = directory / 'wiki.bz2.part'
            partial.write_bytes(payload[:5])
            source = {'id': 'wikipedia', 'path': 'wiki.bz2', 'url': 'https://example.invalid/archive',
                      'size': len(payload), 'sha1': hashlib.sha1(payload).hexdigest()}
            with patch('wikipedia.urllib.request.urlopen', return_value=Response(payload[5:])) as opened:
                download(source, root)
            self.assertEqual(opened.call_args.args[0].get_header('Range'), 'bytes=5-')
            self.assertEqual((directory / 'wiki.bz2').read_bytes(), payload)
            (directory / 'wiki.bz2').unlink()
            partial.write_bytes(payload[:5])
            wrong = Response(payload[5:])
            wrong.headers = {'Content-Range': f'bytes 0-{len(payload) - 1}/{len(payload)}'}
            with patch('wikipedia.urllib.request.urlopen', return_value=wrong), self.assertRaises(ValueError):
                download(source, root)
            self.assertEqual(partial.read_bytes(), payload[:5])

    def test_latest_wikipedia_skips_unfinished_snapshots_and_pins_dated_url(self):
        class Response(io.BytesIO):
            headers = {'Content-Length': '123'}
        def respond(url, **kwargs):
            if url == INDEX:
                return Response(b'<a href="20261101/">new</a><a href="20261001/">complete</a>')
            if url.endswith('dumpstatus.json'):
                status = 'in-progress' if '/20261101/' in url else 'done'
                return Response(json.dumps({'jobs': {
                    'articlesdump': {'status': 'done'},
                    'articlesdumprecombine': {'status': status, 'files': {
                        'zhwiki-20261001-pages-articles.xml.bz2': {'size': 123, 'sha1': 'a' * 40}}},
                }}).encode())
            if url.endswith('sha1sums.txt'):
                return Response(('a' * 40 + '  zhwiki-20261001-pages-articles.xml.bz2\n').encode())
            return Response(b'fixture license')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'licenses').mkdir()
            with patch('wikipedia.CHINESE', root), patch('wikipedia.request', side_effect=respond):
                source = resolve_latest()
            self.assertEqual(source['revision'], '20261001')
            self.assertEqual(source['url'], INDEX + '20261001/zhwiki-20261001-pages-articles.xml.bz2')
            self.assertEqual(source['size'], 123)
            self.assertEqual(source['sha1'], 'a' * 40)
            for document in [source['license_document']] + source['additional_documents']:
                self.assertEqual(digest(root / document['path']), document['sha256'])

    def test_wikipedia_ranges_preserve_prefix_and_publish_only_verified_assembly(self):
        import hashlib
        payload = b'abcdefghijkl'
        class Response(io.BytesIO):
            status = 206
        requests = []
        def respond(request, **kwargs):
            value = request.get_header('Range')
            requests.append(value)
            start, end = map(int, value.removeprefix('bytes=').split('-'))
            response = Response(payload[start:end + 1])
            response.headers = {'Content-Range': f'bytes {start}-{end}/{len(payload)}'}
            return response
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'wiki.bz2'
            prefix = target.with_suffix('.bz2.part')
            prefix.write_bytes(payload[:3])
            source = {'url': 'https://example.invalid/archive', 'size': len(payload),
                      'sha1': hashlib.sha1(payload).hexdigest()}
            with patch('wikipedia.urllib.request.urlopen', side_effect=respond):
                download_ranges(source, target)
            self.assertEqual(target.read_bytes(), payload)
            self.assertEqual(set(requests), {'bytes=3-3', 'bytes=4-7', 'bytes=8-11'})
            self.assertEqual([path.name for path in target.parent.iterdir()], ['wiki.bz2'])
            target.unlink()
            source['sha1'] = '0' * 40
            with patch('wikipedia.urllib.request.urlopen', side_effect=respond), self.assertRaises(ValueError):
                download_ranges(source, target)
            self.assertFalse(target.exists())
            self.assertEqual(len(list(target.parent.glob('*.range-*.part'))), 3)

    def test_wikipedia_refresh_preserves_other_sources_and_records_mirror_transport(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'lock.json'
            retained = {'id': 'fixture', 'unchanged': True}
            lock.write_text(json.dumps({'schema_version': 1, 'language': 'zh-Hans', 'sources': [retained]}))
            source = {'id': 'wikipedia', 'url': INDEX + '20261001/fixture.bz2'}
            with patch('wikipedia.LOCK', lock), patch('wikipedia.resolve_latest', return_value=source), \
                    patch('wikipedia.download', return_value='f' * 64) as downloaded:
                refresh(root, 'your-org')
            updated = json.loads(lock.read_text())
            self.assertEqual(updated['sources'][0], retained)
            wiki = updated['sources'][1]
            self.assertEqual(wiki['url'], INDEX + '20261001/fixture.bz2')
            self.assertEqual(wiki['download_url'],
                             'https://dumps.wikimedia.your.org/zhwiki/20261001/fixture.bz2')
            self.assertEqual(wiki['sha256'], 'f' * 64)
            self.assertEqual(downloaded.call_args.args[0], wiki)
            with patch('wikipedia.LOCK', lock), patch('wikipedia.resolve_latest', return_value=source), \
                    patch('wikipedia.download', return_value='f' * 64):
                refresh(root, 'acc-umu')
            second = json.loads(lock.read_text())
            self.assertEqual(second['sources'][0], retained)
            self.assertEqual(second['sources'][1]['download_url'],
                             'https://ftp.acc.umu.se/mirror/wikimedia.org/dumps/zhwiki/20261001/fixture.bz2')

    def test_lccc_turns_never_join_and_dedup_is_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'dialogues.jsonl.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps(['中文 测试 内容', '独立 对话 内容', '中文 测试 内容']) + '\n')
            source = {'id': 'fixture', 'kind': 'lccc'}
            result = prepare_source(source, archive, root / 'output', self.converter, 0)
            self.assertEqual((root / 'output/text.txt').read_text(), '中文测试内容\n独立对话内容\n')
            self.assertEqual(result['counts']['duplicate_segments'], 1)
            origins = [json.loads(line) for line in (root / 'output/origins.jsonl').read_text().splitlines()]
            self.assertEqual(origins, ['row:1/turn:0', 'row:1/turn:1'])

    def test_output_limit_counts_unique_post_conversion_characters(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'text.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps(['中文测试', '中文测试', '另外测试', '不要保留']) + '\n')
            result = prepare_source({'id': 'fixture', 'kind': 'lccc'}, archive,
                                    root / 'output', self.converter, 8)
            self.assertEqual(result['counts']['characters'], 8)
            self.assertTrue(result['stopped_at_limit'])
            self.assertEqual((root / 'output/text.txt').read_text(), '中文测试\n另外测试\n')

    def test_documentation_stays_in_selected_tree_and_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'docs.tar.gz'
            with tarfile.open(path, 'w:gz') as archive:
                for name in ['root/zh/b.md', 'root/en/a.md', 'root/zh/a.md', 'root/zh/code.py']:
                    content = '中文文档内容'.encode()
                    member = tarfile.TarInfo(name)
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
            rows = list(documents({'kind': 'markdown', 'prefix': 'zh/'}, path, Counter()))
            self.assertEqual([origin for origin, _ in rows], ['zh/b.md', 'zh/a.md'])

    def test_invalid_record_rolls_back_whole_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'bad.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write('["中文测试"]\n{"unexpected": true}\n')
            output = root / 'bundle'
            with self.assertRaises(ValueError):
                with new_directory(output) as staged:
                    prepare_source({'id': 'fixture', 'kind': 'lccc'}, archive,
                                   staged / 'fixture', self.converter, 0)
            self.assertFalse(output.exists())
            self.assertEqual([path.name for path in root.iterdir()], ['bad.gz'])

    def test_existing_output_and_archive_tampering_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            existing = root / 'existing'
            existing.mkdir()
            (existing / 'sentinel').write_bytes(b'keep')
            with self.assertRaises(FileExistsError):
                with new_directory(existing):
                    self.fail('Existing output accepted')
            self.assertEqual((existing / 'sentinel').read_bytes(), b'keep')
            source = {'id': 'existing', 'path': 'sentinel', 'size': 4, 'sha256': digest(existing / 'sentinel')}
            self.assertEqual(verified_archive(source, root), existing / 'sentinel')
            (existing / 'sentinel').write_bytes(b'edit')
            with self.assertRaises(ValueError):
                verified_archive(source, root)


if __name__ == '__main__':
    unittest.main()
