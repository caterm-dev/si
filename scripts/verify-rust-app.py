#!/usr/bin/env python3
"""Check that the staged app contains the Rust conversion resources."""

import json
from pathlib import Path
import re
import sys


def verify_ranking(ranking: Path) -> None:
    def manifest(name):
        path = ranking / name
        if not path.is_file():
            raise ValueError(f"Missing ranking resource: {name}")
        result = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(result, dict):
            raise ValueError(f"Invalid ranking manifest: {name}")
        return result

    ranker = manifest("lambdarank.json")
    for kind in ("pinyin", "reranker"):
        weights = ranking / kind / "weights.f32"
        if not weights.is_file() or not weights.stat().st_size:
            raise ValueError(f"Missing or empty ranking resource: {kind}/weights.f32")
        model = manifest(f"{kind}/model.json")
        digest = model.get("checkpoint_sha256")
        if (model.get("kind") != kind or not isinstance(digest, str)
                or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or ranker.get(f"{kind}_checkpoint_sha256") != digest):
            raise ValueError(f"Ranking checkpoint mismatch: {kind}")


def verify(resources: Path) -> None:
    lexicon = resources / "SIEngine/main.silex"
    if not lexicon.is_file():
        raise ValueError("App is missing SIEngine/main.silex")
    with lexicon.open("rb") as stream:
        if stream.read(8) not in (b"SILEX\0\x01\0", b"SILEX\0\x02\0", b"SILEX\0\x03\0"):
            raise ValueError("App has an invalid SIEngine/main.silex header")
    grams = resources / "SIEngine/words.sigram"
    if not grams.is_file():
        raise ValueError("App is missing SIEngine/words.sigram")
    with grams.open("rb") as stream:
        header = stream.read(8)
        if header not in (b"SIGRAM\x01\0", b"SIGRAM\x02\0", b"SIGRAM\x03\0", b"SIGRAM\x04\0"):
            raise ValueError("App has an invalid SIEngine/words.sigram header")
    if ((resources / "KenLM").exists()
            or any(resources.rglob("si-pinyin.sqlite"))
            or any(resources.rglob("si-english.sqlite"))):
        raise ValueError("App contains obsolete Swift conversion resources")
    verify_ranking(resources / "SIEngine/Ranking")


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--ranking"]:
            verify_ranking(Path(sys.argv[2]))
        else:
            verify(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError) as error:
        sys.exit(f"SI resources: {error}")
