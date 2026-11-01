"""Shared Chinese text cleaning. Never join text across non-Han boundaries."""

import html
import re

# Unified ideographs, including extensions through I. Compatibility ideographs stay
# outside this contract; no NFC/NFKC normalization silently changes their identity.
HAN = re.compile('[\u3400-\u4dbf\u4e00-\u9fff\U00020000-\U0002a6df'
                 '\U0002a700-\U0002b73f\U0002b740-\U0002b81f'
                 '\U0002b820-\U0002ceaf\U0002ceb0-\U0002ebef'
                 '\U0002ebf0-\U0002ee5f\U00030000-\U0003134f\U00031350-\U000323af]+')


def segments(text, converter, minimum=4, maximum=96):
    for run in HAN.finditer(converter.convert(text)):
        value = run.group()
        for offset in range(0, len(value), maximum):
            piece = value[offset:offset + maximum]
            if len(piece) >= minimum:
                yield piece


def markdown_text(text):
    text = re.sub(r'\A\ufeff?---\s*\n.*?\n---[^\n]*(?:\n|$)', ' ', text, flags=re.S)
    text = re.sub(r'(?ms)^\s*(`{3,}|~{3,})[^\n]*\n.*?^\s*\1\s*$', ' ', text)
    text = re.sub(r'(?ms)^\s*(?:`{3,}|~{3,})[^\n]*\n.*\Z', ' ', text)
    text = re.sub(r'<!--.*?-->', ' ', text, flags=re.S)
    text = re.sub(r'<(script|style|code|pre)\b[^>]*>.*?</\1\s*>', ' ', text, flags=re.S | re.I)
    text = re.sub(r'`+[^`]*`+', ' ', text)
    text = re.sub(r'\{\{.*?\}\}', ' ', text, flags=re.S)
    text = re.sub(r'!?\[([^\]]*)\]\([^\n)]*\)', r'\1', text)
    text = re.sub(r'(?m)^\s*(?:\|.*|\[[^\]]+\]:.*)$', ' ', text)
    text = re.sub(r'<[^>]+>', ' ', text)
    # Decode once, then remove escaped HTML too; entities never bridge boundaries.
    return re.sub(r'<[^>]+>', ' ', html.unescape(text))


def web_prose(text):
    sample = text[:4000]
    dense = ''.join(sample.split())
    han_count = sum(len(match.group()) for match in HAN.finditer(dense))
    return (len(dense) >= 64 and han_count >= len(dense) / 2
            and any(len(match.group()) >= 8 for match in HAN.finditer(sample)))
