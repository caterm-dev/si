"""Train-only Unicode character vocabulary with lossless UTF-8 byte fallback."""

from collections import Counter

from .common import fingerprint, read_json, write_json

PAD, BOS, EOS, UNUSED = range(4)
BYTE_OFFSET = 4
CHAR_OFFSET = 260


class Tokenizer:
    def __init__(self, vocab_size, characters):
        if vocab_size < CHAR_OFFSET or len(characters) > vocab_size - CHAR_OFFSET:
            raise ValueError("Vocabulary capacity exceeded")
        if len(set(characters)) != len(characters) or any(len(c) != 1 for c in characters):
            raise ValueError("Character tokens must be unique Unicode scalars")
        self.vocab_size = vocab_size
        self.characters = characters
        self.lookup = {c: i + CHAR_OFFSET for i, c in enumerate(characters)}

    @classmethod
    def fit(cls, rows, vocab_size):
        counts = Counter(c for row in rows for text in (row["input"], row["target"]) for c in text if ord(c) > 127)
        characters = sorted(counts, key=lambda c: (-counts[c], ord(c)))[:vocab_size - CHAR_OFFSET]
        return cls(vocab_size, characters)

    @property
    def active_ids(self):
        return [EOS, *range(BYTE_OFFSET, CHAR_OFFSET + len(self.characters))]

    def encode(self, text):
        result = [BOS]
        for character in text:
            if character in self.lookup:
                result.append(self.lookup[character])
            else:
                result.extend(BYTE_OFFSET + byte for byte in character.encode("utf-8"))
        return [*result, EOS]

    def decode(self, tokens):
        output = bytearray()
        for token in tokens:
            if token == EOS:
                break
            if BYTE_OFFSET <= token < CHAR_OFFSET:
                output.append(token - BYTE_OFFSET)
            elif CHAR_OFFSET <= token < CHAR_OFFSET + len(self.characters):
                output.extend(self.characters[token - CHAR_OFFSET].encode("utf-8"))
            elif token not in (PAD, BOS):
                raise ValueError("Unassigned token in output")
        return output.decode("utf-8", errors="strict")

    def to_dict(self):
        return {"schema_version": 1, "vocab_size": self.vocab_size, "characters": self.characters}

    @property
    def digest(self):
        return fingerprint(self.to_dict())

    def save(self, path):
        write_json(path, self.to_dict())

    @classmethod
    def load(cls, path):
        value = read_json(path)
        if value["schema_version"] != 1:
            raise ValueError("Unsupported tokenizer")
        return cls(value["vocab_size"], value["characters"])
