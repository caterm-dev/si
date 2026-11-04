# English conversation corpus

This offline collection acquires the conversation sources selected in the
[source review](SOURCE_REVIEW.md). It retains the publisher's raw bytes locally
and prepares separate, source-attributed JSONL bundles. It does not start
training, construct spelling/correction labels, change runtime vocabulary or
read private SI data.

## Sources and acquisition

`sources.lock.json` pins exact publisher revisions, file URLs, sizes and SHA-256
hashes. ConvAI2 and BST also retain the publisher's download-manifest hashes;
the five Topical-Chat files were checked against the pinned Git blob IDs.
Full data licenses and relevant publisher descriptions are retained under
`licenses/` and `metadata/`. Software licenses do not replace data licenses.

| Source | Selected text | Data license |
| --- | --- | --- |
| PersonaChat / ConvAI2 | Original complete first-speaker dialogues; profiles, response candidates and alternate speaker presentations excluded. | CC BY 4.0 |
| BlendedSkillTalk | New dialogue turns only; inherited starter turns, profiles, contexts, suggestions and separate EmpatheticDialogues files excluded. | CC BY 4.0 |
| Topical-Chat | Original five conversation JSON files, without ASR variants or external reading-set acquisition. | CDLA-Sharing-1.0 |
| Taskmaster 1, 2 and 3 | Spoken WOz and written self-dialogue utterances, with version and collection method preserved. | CC BY 4.0 |
| ABCD | Original customer/agent utterances, without actions, scenario metadata or delexicalized copies. | MIT |
| Schema-Guided Dialogue | Dialogue utterances, without API calls, frames, schema descriptions or SGD-X variants. | CC BY-SA 4.0 |
| OpenAssistant OASST1 | English, reviewed, nondeleted, nonsynthetic messages with quality >= 0.5 and no positive spam/PII/language-mismatch/inappropriate labels. | Apache-2.0 |

The full Taskmaster repository snapshot includes version 3 as well as versions
1/2. The original ConvAI2 archive includes alternate persona/candidate views;
these remain in raw acquisition but are not independent prepared conversations.
OASST1 retains the publisher's ready-message archive as well as both official
Parquet split files; preparation uses the Parquet files to preserve membership.
Full raw archives can contain metadata or text excluded from prepared output.

The verified **2026-11-04** acquisition pins **833,930,152 bytes** of raw data.
The initial `prepared/dialogue-v1/` bundle retains:

| Source | Dialogue records / trees | Utterances |
| --- | ---: | ---: |
| ConvAI2 | 9,939 | 147,040 |
| BST | 6,808 | 77,501 |
| Topical-Chat | 10,784 | 235,279 |
| Taskmaster 1/2/3 | 54,263 | 1,125,394 |
| ABCD | 10,042 | 184,501 |
| SGD | 22,825 | 463,282 |
| OASST1 English | 3,636 trees | 29,973 |
| **Total** | **118,297** | **2,262,970** |

These are measured retained records across all original splits and explicitly
unsplit data, not training-only counts or independent-conversation counts.
They contain **138,666,423 Unicode code points** of retained utterance text.
[snapshot.json](snapshot.json) records full counts, split breakdowns and hashes;
per-source bundle manifests also record exclusions. Retained counts can differ
from publisher summaries because the exact pinned files and selection rules
are authoritative. OASST1 trees may retain only some original messages.

Run from the repository root with Python 3.12+ and `hf` on PATH:

```sh
# Six readers use only the standard library; OASST1 uses PyArrow.
python3 -m pip install -r corpus/english/requirements.txt

# Explicit network stage; never updates the frozen revisions implicitly.
python3 corpus/english.py fetch
# Offline integrity check of all locally acquired files:
python3 corpus/english.py fetch --check

# New immutable output path; existing bundles are never overwritten.
python3 corpus/english.py prepare --output corpus/english/prepared/dialogue-v1
python3 corpus/english.py check --bundle corpus/english/prepared/dialogue-v1
```

`--source convai2` selects a source; repeat `--source` for multiple sources.
The other IDs are `bst`, `topical-chat`, `taskmaster`, `abcd`, `sgd` and `oasst1`.
`--raw-root PATH` selects a different archive cache. An interrupted non-Hub
transfer restarts its partial file; Hugging Face manages its own transfer
recovery. Cached files must pass their frozen checksums and corrupt caches are
not silently replaced. Preparation/checking do not access the network.

Downloaded data, partial transfers, HF caches and prepared bundles are ignored
by Git. Source locks, notices, scripts, tests and measured snapshot summaries
remain tracked. No data blobs should be forced into Git or LFS.

## Prepared format and boundaries

Each bundle has a copied source lock, licenses/notices and root/source manifests
with code hashes, file hashes, per-split counts and exclusion counts. Each
source directory contains one JSONL file per original split. One record has:

- `id`, `group`: source-local conversation and grouping identity.
- `split`: original upstream split, or explicitly `unsplit` where none exists.
- `origin`: original file/member and conversation or line identity.
- `method`: collection method, retaining guided/spoken/self-dialogue distinctions.
- `turns`: ordered `id`, `speaker`, `text` records with exact retained text.

OASST1 records are **trees**, not linear transcripts. Each retained message also
has its original `parent` ID, including IDs of filtered-out parents. Sibling
replies must never be concatenated as consecutive turns. Tree records sort
messages by ID for deterministic serialization; follow parent edges for context.
The prepared files exclude contributor IDs and unrelated user metadata.

Retained text preserves case, word spaces, apostrophes, punctuation and embedded
line breaks. Empty turns or turns containing unsupported control characters are
excluded and counted; retained neighbors keep their original turn IDs. Do not
infer adjacency across a removed turn. No per-turn deduplication removes common
short acknowledgements. ConvAI2's synthetic-silence second-speaker training views
are excluded to avoid double-counting the same underlying dialogue.

Original validation/test and Topical-Chat frequent/rare boundaries remain
separate. Taskmaster-1's published self-dialogue CSV split assignment is retained.
Taskmaster-3's published TSVs split model examples, with most dialogue IDs
appearing in multiple splits. Complete TM-3 dialogues therefore remain
`unsplit`, with their original memberships retained in `upstream_example_splits`
and overlap counts reported. Taskmaster-1 WOz, Taskmaster-2 and any unassigned
dialogues are also explicitly `unsplit`. Preparation does not invent splits.
Blank Taskmaster speaker labels become the explicit `unknown` role and are
counted, without inferring a speaker from neighboring turns.
Some Taskmaster IDs are reused for distinct transcripts. File/record positions
distinguish those records while the original ID still groups them together;
only byte-identical repeated records are excluded and counted.
This is a corpus acquisition bundle, not a ready-to-train mixed dataset:
future training must select eligible training/unsplit data deliberately, group
related conversations and remove evaluation overlaps. The manifest reports
exact full-transcript cross-split repeats within each source; it is not a
general cross-source, partial-copy or semantic-overlap audit.

Dataset filters and declared licenses do not establish absence of all personal
information, harmful content or third-party quotations. Keep source-specific
license obligations when sharing derived text. No claim about future model
weight licensing or input-method quality follows from this acquisition.

## Verification

```sh
python3 -m unittest corpus.tests.test_english -v
corpus/.venv/bin/python -m unittest discover -s corpus/tests -v
```

Synthetic tests cover exact text, field exclusions, collection methods, original
splits, alternate speaker views, graph edges, checksum corruption, path traversal,
frozen bundles, immutable destinations and rollback. `check` independently
recounts records/turns/characters and verifies frozen source attribution, split
membership, identities, grouping and output checksums. It establishes bundle
integrity, not licensing clearance for every passage or downstream model quality.
