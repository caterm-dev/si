#!/usr/bin/env python3
"""Check that the staged app contains the Rust conversion resources."""

from pathlib import Path
import sys


def verify(resources: Path) -> None:
    lexicon = resources / "SIEngine/main.silex"
    if not lexicon.is_file():
        raise ValueError("App is missing SIEngine/main.silex")
    with lexicon.open("rb") as stream:
        if stream.read(8) not in (b"SILEX\0\x01\0", b"SILEX\0\x02\0", b"SILEX\0\x03\0"):
            raise ValueError("App has an invalid SIEngine/main.silex header")
    if ((resources / "KenLM").exists()
            or any(resources.rglob("si-pinyin.sqlite"))
            or any(resources.rglob("si-english.sqlite"))):
        raise ValueError("App contains obsolete Swift conversion resources")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError) as error:
        sys.exit(f"SI resources: {error}")
