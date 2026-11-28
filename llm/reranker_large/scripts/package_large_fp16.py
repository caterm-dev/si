"""Package the verified weight-edit export as little-endian FP16 for SI."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

import numpy as np


def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def package(source, output):
    provenance = json.loads((source / "provenance.json").read_text())
    weights = source / "rust/weights.f32"
    model = source / "rust/model.json"
    if checksum(weights) != "09351f871623d907059c60deadb9469f12e221cd4566d5e591a7107db64746f2":
        raise ValueError("Expected the selected 19,167-step weight edit")
    if checksum(model) != "89899c46677e727fb0560a746406f5cbe92fcd1254806c9fe2293c37c7a7e3d0":
        raise ValueError("Unexpected tokenizer or tensor layout")
    if output.exists():
        raise FileExistsError(output)
    with tempfile.TemporaryDirectory(dir=output.parent) as work:
        bundle = Path(work) / "bundle"
        bundle.mkdir()
        values = np.fromfile(weights, dtype="<f4").astype("<f2")
        if not np.isfinite(values).all():
            raise ValueError("FP16 conversion overflow")
        values.tofile(bundle / "weights.f16")
        description = json.loads(model.read_text())
        description["weight_format"] = "f16"
        write_json(bundle / "model.json", description)
        metadata = source / "sources/replay/metadata"
        shutil.copy2(metadata / "distillation/source-lock.json", bundle / "source-lock.json")
        notices = bundle / "notices"
        shutil.copytree(metadata / "pretraining/metadata/attribution", notices / "corpus")
        for stage in ("pretraining", "distillation"):
            shutil.copy2(metadata / stage / "NOTICE.md", notices / (stage + ".md"))
        shutil.copy2(metadata / "distillation/metadata/teacher/LICENSE", notices / "Qwen-LICENSE.txt")
        shutil.copy2(metadata / "distillation/metadata/generation/sources.json", notices / "distillation-inventory.json")
        (bundle / "NOTICE.md").write_text(
            "# SI large character reranker\n\n"
            "15,592,320 parameters. The FP32 source mixes 25% continued step 19,167 "
            "with 75% replay step 100 and scales the final LayerNorm by 1.2. "
            "The app stores IEEE binary16 weights and widens them once for FP32 inference. "
            "See source-lock.json and notices/ for corpus provenance, local inventory "
            "identities and Qwen2.5-0.5B Base teacher terms. Source-specific terms apply.\n")
        files = {str(p.relative_to(bundle)): checksum(p) for p in sorted(bundle.rglob("*")) if p.is_file()}
        write_json(bundle / "manifest.json", dict(schema_version=1, kind="si-character-lm-rust-inference",
                   checkpoint_sha256=description["checkpoint_sha256"], weight_edit=provenance, files=files))
        bundle.rename(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    package(args.source, args.output)
