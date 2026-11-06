"""Frozen token cleaning contract for offline KenLM and a future Swift port.

No segmentation, Unicode normalization, case folding or punctuation splitting.
Length means Unicode scalars (Swift unicodeScalars.count), not graphemes/UTF-16.
Numeric grammar uses Unicode decimal digits, ASCII signs/dot/e/E. Rule order is
line rejection, numeric replacement, scalar-length replacement, rare filtering.
Rare counts come only from surviving, base-cleaned training lines. Unseen words
have training count zero, including during heldout processing. Dictionary text
membership is exact and case-sensitive. Synthetic markers bypass rare filtering.
"""
from collections.abc import Mapping, Set
from dataclasses import dataclass
import re

NUM = '<num>'
OOV = '<oov>'
RESERVED = frozenset(('<unk>', '<s>', '</s>'))
GARBLED_MARKERS = ('\ufffd', '锟斤拷', '烫烫烫', '屯屯屯')
MAX_SCALARS = 32
NUMBER = re.compile(r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?')
THRESHOLDS = {'clean1': 0, 'clean2': 5, 'clean3': 20}


def reject_line(line: str) -> bool:
    return any(marker in line for marker in GARBLED_MARKERS)


def base_token(token: str) -> tuple[str, str | None]:
    """Return transformed token and replacement reason, without corpus state."""
    if token in RESERVED:
        raise ValueError('Source contains a KenLM-reserved token')
    if NUMBER.fullmatch(token):
        return NUM, 'numeric'
    if len(token) > MAX_SCALARS:
        return OOV, 'long'
    return token, None


def map_token(token: str, counts: Mapping[str, int], dictionary: Set[str],
              threshold: int = 0) -> tuple[str, str | None]:
    cleaned, reason = base_token(token)
    if reason or cleaned in (NUM, OOV):
        return cleaned, reason
    if threshold and cleaned not in dictionary and counts.get(cleaned, 0) < threshold:
        return OOV, 'rare'
    return cleaned, None


def clean_line(line: str, counts: Mapping[str, int], dictionary: Set[str],
               threshold: int = 0) -> list[str] | None:
    """None rejects a whole garbled line; [] represents an empty input line."""
    if reject_line(line):
        return None
    return [map_token(word, counts, dictionary, threshold)[0] for word in line.split()]


@dataclass(frozen=True)
class FrozenMapper:
    """Byte-stream adapter; decisions delegate to the scalar contract above.

    Base mapping is learned per distinct train token. Heldout-only tokens use
    the same rule and train-count lookup, and never update the training counts.
    """
    counts: Mapping[str, int]
    dictionary: Set[str]
    threshold: int

    def token(self, word: bytes) -> tuple[bytes, str | None]:
        mapped, reason = map_token(word.decode('utf-8'), self.counts,
                                   self.dictionary, self.threshold)
        return mapped.encode('utf-8'), reason
