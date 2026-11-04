# English dialogue data notices

SI's software license does not relicense these datasets. Retain the following
source-specific notices and full license files when redistributing selected or
modified text. `sources.lock.json` records exact publisher revisions, acquisition
URLs, file hashes and retained attribution-document hashes.

| Source | Attribution and retained terms |
| --- | --- |
| PersonaChat / ConvAI2 | Facebook Research / original PersonaChat authors; CC BY 4.0 declared in `metadata/convai2-task.md`. Full terms: `licenses/CC-BY-4.0.txt`. The frozen download script records the publisher archive hash. |
| BlendedSkillTalk | Facebook Research / Eric Michael Smith, Mary Williamson, Kurt Shuster, Jason Weston and Y-Lan Boureau; CC BY 4.0 declared in `metadata/bst-task.md`. Full terms: `licenses/CC-BY-4.0.txt`. Only new dialogue turns are prepared, not separately licensed inherited inputs. |
| Topical-Chat | Copyright Amazon.com, Inc. or its affiliates. Full CDLA-Sharing-1.0 terms: `licenses/topical-chat-DATALICENSE.txt`; description: `metadata/topical-chat-README.md`. No external reading-set fetching is performed. |
| Taskmaster | Google LLC and the authors identified in `metadata/taskmaster-1-README.md`, `taskmaster-2-README.md` and `taskmaster-3-README.md`; each explicitly declares CC BY 4.0. Full terms: `licenses/CC-BY-4.0.txt`. |
| ABCD | Copyright 2021 ASAPP Research. Full MIT terms: `licenses/abcd-LICENSE.txt`; description: `metadata/abcd-README.md`. |
| SGD | Google Research and the authors identified in `metadata/sgd-README.md`. Full CC BY-SA 4.0 terms: `licenses/sgd-LICENSE.txt`; keep applicable ShareAlike obligations for derived text. |
| OASST1 | OpenAssistant / LAION contributors; attribution and dataset description: `metadata/oasst1-README.md`. Full Apache-2.0 terms: `licenses/oasst1-LICENSE.txt`. |

Prepared text is modified by source/field selection, exclusion of duplicate
presentations, filtering of empty/control-containing utterances and OASST1
eligibility filtering. The retained utterance strings themselves are not
normalized, recased, detokenized or rewritten. Format conversion adds SI's
dialogue/provenance envelope; it does not add labels asserting spelling,
correction, intent or candidate-ranking correctness. Source split labels remain
publisher assignments, not newly validated independent benchmarks.

Raw acquisition includes full pinned archives and can contain fields excluded
from prepared output. Any later distribution must inspect the actual selected
content and notices, including separately identified third-party passages.
Licensing of future weights is not determined by this notice. Sources deferred
in `SOURCE_REVIEW.md`, including noncommercial-only dialogue data, are not
implicitly admitted by this collection.
