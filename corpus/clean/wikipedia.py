"""Conservative wikitext-to-prose extraction without expanding templates."""

import html
import re


def remove_nested(text, opening, closing):
    """Remove nested constructs; whitespace keeps surrounding prose apart."""
    if opening not in text:
        return text
    output = []
    position = 0
    depth = 0
    while position < len(text):
        if text.startswith(opening, position):
            if depth == 0:
                output.append(' ')
            depth += 1
            position += len(opening)
        elif depth and text.startswith(closing, position):
            depth -= 1
            position += len(closing)
        else:
            if depth == 0:
                output.append(text[position])
            position += 1
    return ''.join(output)


def wikitext(text):
    text = re.sub(r'<!--.*?(?:-->|\Z)', ' ', text, flags=re.S)
    block_tags = 'ref|references|math|chem|code|pre|source|syntaxhighlight|gallery|timeline|score'
    text = re.sub(r'<(?:' + block_tags + r')\b[^>]*?/\s*>', ' ', text, flags=re.S | re.I)
    text = re.sub(r'<(' + block_tags + r')\b[^>]*>.*?(?:</\1\s*>|\Z)', ' ', text, flags=re.S | re.I)
    text = remove_nested(text, '{{', '}}')
    text = remove_nested(text, '{|', '|}')
    # Innermost links first: a file caption can itself contain ordinary links.
    pattern = re.compile(r'\[\[([^\[\]]*)\]\]')

    def link(match):
        parts = match.group(1).split('|')
        target = parts[0].lstrip(':').strip()
        if ':' in target:
            return ' '
        return parts[-1] if len(parts) > 1 else target.split('#')[0]

    while pattern.search(text):
        text = pattern.sub(link, text)
    text = re.sub(r'\[(?:https?|ftp)://[^\s\]]+(?:\s+([^\]]*))?\]',
                  lambda match: match.group(1) or ' ', text)
    text = re.sub(r'-\{.*?\}-', ' ', text, flags=re.S)
    text = re.sub(r'<[^>]+>', ' ', text)
    text = re.sub(r'(?m)^\s*[=]+[^\n]*$', ' ', text)
    text = re.sub(r'(?m)^\s*\[\[?[^\n]*$', ' ', text)
    text = re.sub(r"'{2,}", ' ', text)
    return re.sub(r'<[^>]+>', ' ', html.unescape(text))
