#!/usr/bin/env python3
"""Check that the staged app contains the Rust conversion resources."""

import hashlib
import json
from pathlib import Path
import sys


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
    ranking = resources / "SIEngine/Ranking"
    if ranking.exists() or ranking.is_symlink():
        raise ValueError("App contains obsolete SIEngine/Ranking resources")
    verify_reranker(resources / "SIEngine/RerankerSmall", "weights.f32")
    verify_reranker(resources / "SIEngine/RerankerLarge", "weights.f16")


def verify_reranker(directory: Path, weights: str) -> None:
    manifest = directory / "manifest.json"
    if not manifest.is_file():
        raise ValueError(f"App is missing SIEngine/{directory.name}/manifest.json")
    data = json.loads(manifest.read_text(encoding="utf-8"))
    files = data.get("files") if isinstance(data, dict) else None
    required = {"model.json", weights, "NOTICE.md", "source-lock.json"}
    if not isinstance(files, dict) or not required.issubset(files):
        raise ValueError(f"Invalid SIEngine/{directory.name} resource manifest")
    for name, expected in files.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Invalid SIEngine/{directory.name} resource path")
        path = directory / relative
        if not path.is_file():
            raise ValueError(f"App is missing SIEngine/{directory.name}/{name}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise ValueError(f"Checksum differs for SIEngine/{directory.name}/{name}")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError) as error:
        sys.exit(f"SI resources: {error}")
