#!/usr/bin/env python3
"""Check the generated site's routes, anchors and local-only runtime assets."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parent.parent / '.build' / 'website'
ROUTES = ('', 'privacy/', 'terms/', 'zh/', 'zh/privacy/', 'zh/terms/')


class Page(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []
        self.alternates = {}
        self.lang = None
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if 'id' in attrs:
            assert attrs['id'] not in self.ids, f"Duplicate ID: {attrs['id']}"
            self.ids.add(attrs['id'])
        if tag == 'html':
            self.lang = attrs.get('lang')
        for attribute in ('href', 'src'):
            if attribute in attrs:
                self.links.append(attrs[attribute])
        if tag == 'link' and attrs.get('rel') == 'alternate':
            self.alternates[attrs['hreflang']] = attrs['href']
        if tag in ('script', 'img') or (tag == 'link' and attrs.get('rel') in ('stylesheet', 'icon')):
            url = attrs.get('src', attrs.get('href', ''))
            assert not urlsplit(url).netloc, f'Remote runtime asset: {url}'


pages = {}
for route in ROUTES:
    html = (ROOT / route / 'index.html').read_text()
    assert '{{' not in html, f'Unresolved template: {route}'
    pages[route] = Page(html)
    assert pages[route].lang == ('zh-CN' if route.startswith('zh/') else 'en')

for prefix in ('/', '/si/'):
    base = 'https://si.invalid' + prefix
    for route, page in pages.items():
        current = base + route
        for link in page.links:
            target = urlsplit(urljoin(current, link))
            if target.netloc != 'si.invalid':
                assert target.scheme == 'https', f'Insecure external link: {link}'
                continue
            assert target.path.startswith(prefix), f'Link escapes hosting path: {route}: {link}'
            local = unquote(target.path[len(prefix):])
            file = ROOT / local
            if target.path.endswith('/'):
                file /= 'index.html'
            assert file.is_file(), f'Missing target: {route}: {link}'
            if target.fragment:
                destination = local if local.endswith('/') or not local else local.removesuffix('index.html')
                assert unquote(target.fragment) in pages[destination].ids, f'Missing anchor: {route}: {link}'
        kind = route.removeprefix('zh/')
        for lang, expected in (('en', kind), ('zh-CN', 'zh/' + kind), ('x-default', kind)):
            assert urljoin(current, page.alternates[lang]) == base + expected, f'Wrong alternate: {route}: {lang}'

print('Verified six localized pages: local links, anchors, language alternates, and runtime assets at / and /si/.')
