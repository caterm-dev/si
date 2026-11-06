#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
archive="corpus/.cache/kenlm.tar.gz"
expected="6bb66b6c17f6d23907bd6258ee585328b3e5f5f2b201d41c5f6bd0c390c2c913"
mkdir -p corpus/.cache
if [ ! -f "$archive" ]; then
  curl -L --fail https://kheafield.com/code/kenlm.tar.gz -o "$archive.download"
  mv "$archive.download" "$archive"
fi
python3 - "$archive" "$expected" <<'PY'
import hashlib,sys,tarfile
from pathlib import Path
archive=Path(sys.argv[1])
with archive.open('rb') as f: actual=hashlib.file_digest(f,'sha256').hexdigest()
if actual!=sys.argv[2]:raise SystemExit('Official archive changed: retain/reuse the pinned archive; do not silently adopt another version')
root=Path('corpus/.cache/kenlm-src')
root.mkdir(exist_ok=True)
if not (root/'kenlm/CMakeLists.txt').exists():
 with tarfile.open(archive) as f:f.extractall(root,filter='data')
PY
cmake -S corpus/.cache/kenlm-src/kenlm -B corpus/.cache/kenlm-build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_TESTING=OFF
cmake --build corpus/.cache/kenlm-build --target lmplz build_binary query -j 6
