"""Reuse SI's lossless character/byte encoding, fitting only LM training text."""

from llm.pinyin_to_text.tokenizer import BOS, EOS, PAD, CHAR_OFFSET, Tokenizer


def fit_counts(counts, capacity):
    characters = sorted((c for c in counts if ord(c) > 127),
                        key=lambda c: (-counts[c], ord(c)))[:capacity - CHAR_OFFSET]
    return Tokenizer(capacity, characters)
