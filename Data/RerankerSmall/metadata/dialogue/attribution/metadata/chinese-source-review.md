# Chinese conversation source review

Reviewed **2026-11-04**, for SI's conversation-focused offline corpus.
These are source-research notes. Current download scope and exact raw-file
checksums are in ../download-manifest.json. No cleaned dataset or training is
maintained by this download-only stage.

## What is already available

### LCCC-base training archive

The existing Chinese lock selects `lccc_base_train.jsonl.gz` from `silver/lccc`,
revision `5bd582fa28cd7143f2f9c852e08e23089d677c44`. The local archive exists at
`raw/lccc/lccc_base_train.jsonl.gz`: **369,854,377 bytes**, reverified SHA-256
`2162e0ed923fba62329cabf7e1493fbe59248afc94a62508e4abdea61e624627`.

The publisher describes [LCCC-base](https://github.com/thu-coai/CDial-GPT) as a
cleaned Weibo-derived collection of approximately 6.8 million single/multi-turn
conversations. That is a whole-release description, not a newly measured count
of SI's training-only file. LCCC-large additionally mixes several other corpora;
its source/license scope is not interchangeable with base.

SI's existing [fragment snapshot](snapshot.json) retains **1,160,555 LCCC Han
fragments and 9,999,997 Han characters**, stopped at a character limit. Those
are not conversation counts. `corpus/prepare.py` and `clean/chinese.py` remove
non-Han boundaries and retain 4–96-character fragments. Complete turns,
punctuation, code-switching and multi-turn structure therefore need a separate
reader from the preserved raw archive, rather than reconstruction from fragments.

The [original repository license](https://github.com/thu-coai/CDial-GPT/blob/master/LICENSE)
is MIT, and SI's retained mirror card declares MIT, but its detailed data-license
section is incomplete. The existing [notice](NOTICE.md) records that distinction.
Neither a repository software license nor a mirror label by itself settles all
rights in the underlying social-media text. Preserve that qualification rather
than upgrading it to blanket redistribution clearance.

### OASST1 Chinese messages in the existing multilingual raw files

The [English acquisition](../english/README.md) already downloaded OASST1's
multilingual official Parquet split files at revision
`fdf72ae0827c1cda404aff25b6603abec9e3399b`. A read-only count found:

| Original split | Messages with `lang == zh` | Eligible messages | Trees containing eligible messages |
| --- | ---: | ---: | ---: |
| Train | 3,314 | 1,404 | 357 |
| Validation | 134 | 58 | 13 |
| Total | 3,448 | 1,462 | 370 |

Eligibility here uses the existing English selection criteria except for the
language: reviewed, nondeleted, nonsynthetic, quality >= 0.5, and no positive
spam/PII/language-mismatch/inappropriate labels. These are inspected candidate counts; no Chinese filtering output is retained. The [publisher card](https://huggingface.co/datasets/OpenAssistant/oasst1)
declares Apache-2.0. This can supplement human-written prompts and replies, but
is small and assistant-oriented. Preserve split membership and original parent
edges; filters do not establish complete PII or content-rights clearance.

## Most useful additions to investigate first

| Source | Content and published scale | Terms found | Assessment for SI |
| --- | --- | --- | --- |
| [KdConv](https://github.com/thu-coai/KdConv) | 4,500 conversations and about 86,000 utterances, covering film, music and travel; sustained knowledge-grounded exchanges. | Publisher repository has an [Apache-2.0 license](https://github.com/thu-coai/KdConv/blob/master/LICENSE). Inspect the chosen snapshot and any accompanying data exceptions before admission. | A strong first candidate for topic discussion. Select `messages[].message`; do not silently treat knowledge triples, encyclopedia paragraphs or topic metadata as conversation. Small/narrow domain coverage is a limitation. |
| [CrossWOZ](https://github.com/thu-coai/CrossWOZ) | About 6,000 human WOz dialogue sessions and 102,000 utterances across hotels, restaurants, attractions, metro and taxis. | Publisher repository has an [Apache-2.0 license](https://github.com/thu-coai/CrossWOZ/blob/master/LICENSE); confirm the pinned data's notices. | A strong first candidate for practical requests, alternatives, constraints and clarification. Keep user/system turns and original splits; exclude task descriptions, database/state fields and dialogue-act metadata. Task roleplay is not unrestricted social chat. |
| [DuLeMon](https://github.com/PaddlePaddle/Research/tree/master/NLP/ACL2022-DuLeMon) | Crowdworker conversations conditioned on personal interests and experiences, with a user and chatbot role. The [paper](https://aclanthology.org/2022.findings-acl.207/) explains the translation/rewriting of some PersonaChat profiles. | The containing Research repository has [Apache-2.0](https://github.com/PaddlePaddle/Research/blob/master/LICENSE); the inspected dataset directory does not carry a separate license. Its [download script](https://github.com/PaddlePaddle/Research/blob/master/NLP/ACL2022-DuLeMon/data/download_dulemon.sh) points to a Baidu-hosted ZIP. The archive's data notices were not inspected. | Particularly relevant to everyday persona chat, but data-grant scope remains pending. Audit the archive and translated-profile attribution before admission. Extract actual turns separately from profile/memory labels; retain Self/Both or other presentation relationships to prevent duplicate counting. The dataset's memory task does not enable runtime memory in SI. |
| [XPersona Chinese](https://github.com/HLTCHKUST/Xpersona) | A Chinese extension of English PersonaChat/ConvAI2, alongside five other added languages. | Repository code is MIT; the inherited PersonaChat attribution/license and translation-release terms must be checked separately. | A secondary translation-based supplement, not independent native Chinese conversation. Audit machine/human translation provenance and preserve cross-language dialogue families with the English data. |

Repository license evidence above is a reason to inspect these sources first,
not proof that every external knowledge passage has the same grant. Freeze
actual release/commit, files, checksums and retained data notices before adding
an executable fetch entry.

## Relevant content outside the default reusable collection

| Source | Why it is interesting | Why it is deferred |
| --- | --- | --- |
| [NaturalConv](https://ojs.aaai.org/index.php/AAAI/article/view/17649) | About 19,900 topic-driven conversations and 400,000 utterances, allowing natural topic shifts. | The [Tencent dataset terms](https://ailab.tencent.com/ailab/nlp/dialogue/papers/NaturalConv_Release_license.pdf) grant limited personal/noncommercial research use and restrict redistribution and alternate-source downloads. Content fit does not make this a default broadly reusable source. |
| [DuRecDial 2.0](https://github.com/liuzeming01/DuRecDial) | Human recommendation conversations; about 8,200 Chinese/English aligned dialogue pairs, not 16,500 independent Chinese conversations. | Publisher explicitly distinguishes its data's CC BY-NC-SA 4.0 restriction from Apache-2.0. Do not infer commercial permission from the software license or unrelated papers. This finding is specific to the reviewed 2.0 release; older releases need their own review. |
| [Pchatbot](https://github.com/qhjqhj00/SIGIR2021-Pchatbot) | Very large Weibo and judicial-forum exchanges; conversation history and anonymized user identities. | Publisher explicitly assigns the dataset CC BY-NC 2.0, while repository software is Apache-2.0. Access/application and personal-history fields need separate handling. Scale does not override the noncommercial scope. |
| [CPED](https://github.com/scutcyr/CPED) | More than 12,000 emotional/personality dialogue segments and 133,000 utterances. | Publisher says it originates from 40 television series. The repository's Apache-2.0 license does not by itself establish rights to redistribute the underlying scripts/audio/video. Treat it as a passage-rights review, not a default download. |
| [CS-Dialogue](https://huggingface.co/datasets/BAAI/CS-Dialogue) | 104 hours of spontaneous Mandarin/English conversation, directly relevant to code-switching. | Publisher declares CC BY-NC-SA 4.0; access terms additionally restrict redistribution and require honoring participant withdrawal. An academic-only speech resource, not a default reusable text corpus. |
| [OpenDialog](https://huggingface.co/datasets/k2-fsa/OpenDialog) | Publisher reports 1,759 hours of Chinese in-the-wild spoken dialogue. | Dataset card declares CC BY-NC 4.0. Do not confuse the speech toolkit/model code license with the data. ASR-derived transcripts also differ from typed text. |

## Possible later cleaning work

The original source files are retained without filtering or text changes.
A later, separately requested cleaning stage can decide source selection,
text restoration, dialogue grouping and evaluation-overlap handling. Dataset
rights qualifications above continue to apply; no training is started here.
