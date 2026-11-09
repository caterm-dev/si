"""Shared offline readers for pinned Chinese document archives."""

import bz2
import gzip
import json
import re
import tarfile
import xml.etree.ElementTree as ET

if __package__:
    from .clean.chinese import markdown_text, web_prose
    from .clean.wikipedia import wikitext
else:
    from clean.chinese import markdown_text, web_prose
    from clean.wikipedia import wikitext

def documents(source, path, counts, *, preserve_lccc_spacing=False, include_title=False):
    if source['kind'] == 'wikipedia':
        with bz2.open(path, 'rb') as handle:
            events = ET.iterparse(handle, events=('start', 'end'))
            _, root = next(events)
            namespace = root.tag.partition('}')[0] + '}' if root.tag.startswith('{') else ''
            for event, page in events:
                if event != 'end' or page.tag != namespace + 'page':
                    continue
                counts['records_read'] += 1
                if page.findtext(namespace + 'ns') != '0':
                    counts['nonarticle_pages'] += 1
                elif page.find(namespace + 'redirect') is not None:
                    counts['redirect_pages'] += 1
                else:
                    revision = page.find(namespace + 'revision')
                    if revision is None:
                        raise ValueError('Wikipedia page has no current revision')
                    page_id = page.findtext(namespace + 'id')
                    revision_id = revision.findtext(namespace + 'id')
                    if not page_id or not revision_id or not page_id.isdigit() or not revision_id.isdigit():
                        raise ValueError('Wikipedia page/revision has no numeric ID')
                    model = revision.findtext(namespace + 'model')
                    if model not in (None, 'wikitext'):
                        counts['nonwikitext_pages'] += 1
                    else:
                        text = revision.findtext(namespace + 'text') or ''
                        origin = f'https://zh.wikipedia.org/w/index.php?curid={page_id}&oldid={revision_id}'
                        title = page.findtext(namespace + 'title') or ''
                        prefix = title + '\n\n' if include_title and title else ''
                        yield origin, prefix + wikitext(text)
                # Clearing only the element leaves empty pages attached to the
                # root. Clear the root too, keeping memory independent of page count.
                page.clear()
                root.clear()
        return
    if source['kind'] in ('lccc', 'mc4'):
        with gzip.open(path, 'rt', encoding='utf-8') as handle:
            for index, line in enumerate(handle, 1):
                counts['records_read'] += 1
                row = json.loads(line)
                if source['kind'] == 'lccc':
                    if not isinstance(row, list) or not all(isinstance(turn, str) for turn in row):
                        raise ValueError('Invalid LCCC record at row ' + str(index))
                    for turn_index, turn in enumerate(row):
                        # This release is word-tokenized. Only its ASCII token spaces
                        # are removed; turns and punctuation always remain boundaries.
                        restored = (re.sub(r'(?<=[\u3400-\u9fff，。！？；：、]) +'
                                           r'(?=[\u3400-\u9fff，。！？；：、])', '', turn)
                                    if preserve_lccc_spacing else turn.replace(' ', ''))
                        yield f'row:{index}/turn:{turn_index}', restored
                else:
                    if not isinstance(row, dict) or not isinstance(row.get('text'), str):
                        raise ValueError('Invalid mC4 record at row ' + str(index))
                    if web_prose(row['text']):
                        yield f'row:{index}', row['text']
                    else:
                        counts['nonprose_documents'] += 1
        return
    # A pinned tarball has deterministic member order. Stream once rather than
    # sorting members and repeatedly seeking backwards through a gzip archive.
    with tarfile.open(path, 'r|gz') as archive:
        for member in archive:
            relative = member.name.partition('/')[2]
            if (not member.isfile() or not relative.startswith(source['prefix'])
                    or not relative.endswith(('.md', '.html'))):
                continue
            if member.size > 8 * 1024 * 1024:
                raise ValueError('Documentation file exceeds 8 MiB: ' + relative)
            counts['records_read'] += 1
            with archive.extractfile(member) as handle:
                text = handle.read().decode('utf-8')
            yield relative, markdown_text(text)

