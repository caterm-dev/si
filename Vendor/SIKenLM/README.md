# KenLM query library

The query sources are taken byte for byte from the official archive pinned in
[the source lock](../../corpus/kenlm/source.lock.json). The archive's
`GIT_REVISION` identifies `b32c19389737a5def8bbc4623de809ced3091187`.
The file selection follows upstream's `compile_query_only.sh` and omits CLI
entry points, tests, and estimation tools. Upstream licenses most query
sources under LGPL-2.1-or-later, with exceptions identified in the file headers.
The later-version option supports use with SI's GPLv3 source. The upstream
license texts and double-conversion notice are retained in `Notices/`.
SI's Objective-C++ adapter is separate from the upstream sources. The
compiled model remains a local artifact with separate corpus terms recorded
in the KenLM experiment record.
