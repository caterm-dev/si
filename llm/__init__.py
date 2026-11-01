"""Independent offline model families for SI."""

from pathlib import Path as _Path

# Keep old imports such as llm.train loading the relocated original modules.
# This is one implementation; model files and checkpoint code identities stay intact.
__path__.append(str(_Path(__file__).parent / "pinyin_to_text"))
