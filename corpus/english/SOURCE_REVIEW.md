# English corpus source review

Reviewed on **2026-11-04**. This document records source-selection decisions.
The selected conversation sources now have an explicit acquisition/preparation
workflow in [the English guide](README.md), with a separate source lock and
retained attribution. Prose sources and deferred alternatives below are not
implicitly acquired. No training or changes to runtime dictionaries are implied.

## Conversation-first selection

The user's priority is English conversation. Prioritize everyday exchanges and
practical requests; the previously reviewed technical prose is supplemental.
The recommendations below apply to the specified upstream text,
subject to its notices and any file-specific exceptions. Public availability
alone does not establish permission to reuse content.

| Source | Conversation value | Published terms and selection boundary | Priority |
| --- | --- | --- | --- |
| PersonaChat / ConvAI2 | Human-written, persona-conditioned chit-chat about interests and personal topics. More relevant to informal typing than documentation. | The publisher's [ConvAI2 task declaration](https://github.com/facebookresearch/ParlAI/blob/main/parlai/tasks/convai2/README.md) specifies CC BY 4.0. Pin the original archive and retain its notices. Original/revised persona variants and the two speaker perspectives must not be counted as independent conversations or leak across splits. | First batch: everyday conversation. Fictional profiles and elicited exchanges are not naturally occurring chat logs. |
| BlendedSkillTalk (BST) | About 7,000 conversations combining personality, empathy and knowledge. Human crowdworkers converse, with one worker receiving suggested replies. | The [publisher task README](https://github.com/facebookresearch/ParlAI/blob/main/parlai/tasks/blended_skill_talk/README.md) declares CC BY 4.0 for BST. Select the new BST dialogue turns; separately review inherited starter turns, persona/context fields and suggestions. The [download script](https://github.com/facebookresearch/ParlAI/blob/main/parlai/tasks/blended_skill_talk/build.py) also fetches separate EmpatheticDialogues-derived files; those are not admitted by BST's license label. | First batch after field-level review. Retain the guided/free distinction; do not describe all turns as spontaneous, unassisted chat. |
| Topical-Chat | Publisher reports 10,784 human-human conversations and 235,281 utterances over eight broad topics, with no assigned user/assistant roles. Useful for sustained interest/topic discussion. | The publisher's [DATALICENSE](https://github.com/alexa/Topical-Chat/blob/master/DATALICENSE) specifies CDLA-Sharing-1.0, distinct from its software license. Retain attribution/license and modification notices; published enhanced data stays under its sharing terms. Select `conversations/` message fields, not externally fetched reading sets. Check identified quotations/third-party passages separately. | First batch after content/notice review. Knowledge-grounded discussion can sound more like fact exchange than casual messaging. |
| Taskmaster-1 and Taskmaster-2 | [TM-1](https://github.com/google-research-datasets/Taskmaster/blob/master/TM-1-2019/README.md): 13,215 dialogues, including 5,507 two-person spoken and 7,708 written self-dialogues. [TM-2](https://github.com/google-research-datasets/Taskmaster/blob/master/TM-2-2020/README.md): 17,289 two-person spoken dialogues involving restaurants, food, travel, movies, music and sports. | Both dataset READMEs explicitly grant CC BY 4.0. Extract utterance text with source/conversation/turn/speaker identity; keep instructions, annotations and API payloads separate. Spoken user turns are transcriptions; written self-dialogues are one worker writing both sides. | First batch: prioritize TM-2 and distinguish TM-1 collection methods. Good practical questions, alternatives and clarifications; automated-interface roleplay differs from social chat. |
| ABCD | Publisher describes over 10,000 human-human customer-service chats with 55 intents. Useful for refunds, account issues, complaints and problem clarification. | The [publisher repository](https://github.com/asappresearch/abcd) contains code and data under its [MIT license](https://github.com/asappresearch/abcd/blob/master/LICENSE); inspect the pinned data's notices. Extract original utterances rather than action records, scenario metadata or delexicalized placeholder text. Preserve original splits. | First batch supplement for service conversations, with entity/contact screening. Narrow service scenarios should not dominate general chat. |
| Schema-Guided Dialogue (SGD) | Over 20,000 task-oriented conversations spanning 20 domains. Useful for appointments, travel, calendars, weather and service requests. | The [publisher README](https://github.com/google-research-datasets/dstc8-schema-guided-dialogue) explicitly licenses SGD and SGD-X under CC BY-SA 4.0. Keep ShareAlike text separate and preserve original splits. Import utterances, not schema descriptions, slot values or service calls. | Second batch: useful domain breadth, but simulator-generated dialogue plans with crowdworker wording are less spontaneous than human-human chat. SGD-X schema variants are not new independent conversations. |

Published sizes above describe complete upstream datasets, including held-out
data, and are not measured SI training counts. Training preparation must select
only eligible training conversations and report its own retained counts.
For SI, a useful corpus improves the representation of text a person might
type; conversational-agent response benchmarks alone do not establish that.
Preserve contractions, casing, punctuation, short acknowledgements and turn
boundaries. Do not turn persona profiles, knowledge paragraphs, instructions or
API actions into pretend user utterances. Keep source, role and collection
method available for later sampling; choose mixing ratios only after inspecting
the retained data and evaluating the intended input task.

### Further dialogue candidates

- [Multi-Session Chat (MSC)](https://parl.ai/projects/msc/) extends PersonaChat
  into human-human conversations across sessions, making it relevant to ongoing
  social exchanges. Its session-1 overlap needs deduplication. The inspected
  task code's MIT header licenses software; the downloadable data's license
  still needs verification before admission.
- [WildChat-1M](https://huggingface.co/datasets/allenai/WildChat-1M) and
  [WildChat-4.8M](https://huggingface.co/datasets/allenai/WildChat-4.8M) contain
  real user/ChatGPT interactions. Current publisher cards declare ODC-BY;
  WildChat-1M records the 2024 change from the older ImpACT license. Evaluate
  the exact release, collection consent, third-party content and retained
  metadata before admission. Consider English user turns separately from
  machine replies; exclude IP hashes, geography, headers and contributor
  identity from prepared text. A toxicity-filtered release does not establish
  removal of all personal information or make it ordinary human-human chat.
- [EmpatheticDialogues](https://github.com/facebookresearch/EmpatheticDialogues)
  is relevant to emotional everyday exchanges, but its [CC BY-NC 4.0
  license](https://github.com/facebookresearch/EmpatheticDialogues/blob/main/LICENSE)
  keeps it outside the default broadly reusable collection, like DailyDialog.
  Preserve that boundary when reviewing BST's separately downloaded inputs.

## Previously reviewed prose and assistant sources

| Source | Proposed acquisition and scope | Published terms and obligations | Suitability and limits |
| --- | --- | --- | --- |
| English Wikipedia | A dated, completed official `enwiki` article dump; namespace-0, nonredirect current article prose only. | [Dump licensing](https://dumps.wikimedia.org/legal.html) and [Wikimedia terms](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use): CC BY-SA 4.0 text route, with exceptions. Retain article/revision URLs, attribution, license and modification notices; keep derived text under applicable ShareAlike terms. Exclude media and identified separately restricted material. | General vocabulary and explanatory prose; encyclopedic style does not represent everyday typing. Preserve article grouping and original English punctuation/spacing. |
| Kubernetes English documentation | Pinned `kubernetes/website` archive, `content/en/` prose. | [CC BY 4.0](https://github.com/kubernetes/website/blob/main/LICENSE). Retain attribution, license and modification notices; inspect file-specific exceptions. | Technical prose; an English tree can reuse the archive already pinned for Chinese after verifying its English scope and notices. Do not count code, templates or navigation as prose. |
| Python documentation | Pinned CPython release/commit archive, English narrative prose under `Doc/`. | [PSF License Version 2 and retained historical notices](https://docs.python.org/3/license.html). Preserve applicable copyright/license notices and summarize modifications. Code examples have additional licensing, but are outside this prose selection. | Technical explanatory writing. reStructuredText needs its own extraction, including directive/code exclusion. Do not import the whole repository as text. |
| The Rust Programming Language | Pinned `rust-lang/book` archive, English chapter prose under `src/`. | Upstream [MIT](https://github.com/rust-lang/book/blob/main/LICENSE-MIT) and [Apache-2.0](https://github.com/rust-lang/book/blob/main/LICENSE-APACHE) license files. Retain both upstream notices and record the selected license route when pinning. | Coherent technical chapters. Use repository text, not the separately published commercial book edition; remove code and mdBook directives. |
| OpenAssistant OASST1 English subset | Pinned [publisher dataset](https://huggingface.co/datasets/OpenAssistant/oasst1); English messages from its training split. | The publisher's [dataset card](https://huggingface.co/datasets/OpenAssistant/oasst1/blob/main/README.md) declares Apache-2.0 for the dataset. Retain card, license and attribution; inspect the pinned release's notices. | Conversation supplement, especially prompts; assistant replies are not ordinary user typing. Select reviewed, nondeleted, nonsynthetic English messages and screen available spam/PII/quality labels. Keep message/tree IDs for provenance and grouping, without copying contributor IDs into prepared text. These filters do not guarantee absence of problematic content. |
| MDN English documentation | Pinned `mdn/content` archive, prose under `files/en-us/`. | [CC BY-SA 2.5 for prose](https://github.com/mdn/content/blob/main/LICENSE.md), distinct from code-example licensing. Retain attribution, original paths, license and modification notices; keep derived prose under applicable ShareAlike terms. | Useful web/software language. Keep separate from permissively licensed sources and exclude code/macros. Existing Chinese MDN archives contain translations, not this English source tree. |

These are suitable candidates for an offline collection under their respective
terms, including commercial reuse where those terms allow it. They do not all
become GPLv3 because SI's software is GPLv3. Store source-specific text and terms
separately. This review does not determine licensing of future trained weights;
that needs review against the actual data selection and intended distribution.

## Useful alternatives requiring more selection work

| Source | Finding | Decision |
| --- | --- | --- |
| TensorFlow English documentation | The [source repository](https://github.com/tensorflow/docs/blob/master/README.md) declares Apache-2.0, while [published documentation](https://www.tensorflow.org/community/contribute/docs) distinguishes CC BY 4.0 page content and Apache-2.0 code samples. Markdown and notebook prose need explicit extraction scopes. | Usable through the applicable grant, but pin the acquisition route and check per-file notices before recording one license for the selected text. Do not copy the Chinese lock's blanket license label without checking the English selection. |
| MultiWOZ | The [publisher repository](https://github.com/budzianowski/multiwoz) provides human-human task conversations and an [MIT license](https://github.com/budzianowski/multiwoz/blob/master/LICENSE). The README describes that grant in terms of its toolkit; several data versions and external corrections exist. | A promising conversation alternative. Confirm the chosen archive/version's data-license scope and notices before admission. Retain original dialogue splits; booking/travel conversations are narrow and contain entity/contact strings. |
| English Wikinews | Its [current copyright policy](https://en.wikinews.org/wiki/Wikinews:Copyright) distinguishes CC BY 4.0 recent material, CC BY 2.5 older material and early public-domain text. The generic Wikimedia dump legal page still describes the older rule. | Potential news supplement; resolve applicable article/revision terms and date boundaries before importing. Do not label the whole dump CC BY 2.5 or CC BY 4.0. |
| Project Gutenberg | [Publisher guidance](https://www.gutenberg.org/policy/permission.html) makes US-only public-domain determinations, includes some copyrighted books, and distinguishes trademark conditions. | Consider only an explicit title/edition allowlist after jurisdiction and per-book review. Do not bulk-admit the catalog as universally public-domain text. Older literary prose also differs from contemporary typing. |

## Not in the default initial collection

English C4 is technically convenient: the [publisher card](https://huggingface.co/datasets/allenai/c4)
offers English shards and declares ODC-BY plus Common Crawl terms. However,
[ODC-BY](https://opendatacommons.org/licenses/by/1-0/) covers database rights, not
all rights in individual contents, and [Common Crawl's terms](https://commoncrawl.org/terms-of-use)
require respecting third-party rights. Therefore a downloaded C4 shard is not
automatically a cleared, freely redistributable collection of web articles.
Keep it outside the initial default set pending a content-rights selection
policy. The existing Chinese mC4 pin does not establish English content rights.
Other bulk web mixtures need their own source review; a mixture-level license
label is insufficient.

DailyDialog is also excluded from the initial set: its [published dataset
metadata](https://huggingface.co/datasets/li2017dailydialog/daily_dialog) declares
CC BY-NC-SA 4.0. A noncommercial restriction does not fit the intended broadly
reusable collection. This is a scope decision, not a claim that research use is
prohibited.

## Acquisition and preparation requirements

Before a recommended source becomes an executable fetch entry:

1. Freeze the repository commit or completed dated dump and exact selected
   paths/split. Record canonical download URL, size, SHA-256, and official
   checksums where supplied. Inspect the chosen snapshot's file-level exceptions.
2. Retain full licenses, applicable notices, dataset cards and their hashes.
   Record the content license separately from software/tool licenses. Dynamic
   links in this review are evidence pointers, not reproducibility pins.
3. Download raw archives only through an explicit acquisition stage. Keep raw
   and prepared data local and ignored, consistent with the existing corpus
   policy; this directory must not grow tracked data blobs.
4. Preserve English case, word spaces, apostrophes, punctuation and paragraph/
   document boundaries. Do not use the Han-only fragment cleaner, concatenate
   unrelated turns, or silently convert prose into input/output correction pairs.
5. Keep aligned origins and document/dialogue groups. Count and deduplicate
   deterministically, report exclusions and limits, preserve upstream held-out
   splits, and avoid allowing copied pages or conversation branches across future
   model splits. Keep evaluation data out of training selections.
6. Keep sources and licenses separate in immutable output bundles with hashes
   and verification reports. Corpus preparation must not start training, modify
   input-method behavior, read private SI data or overwrite existing experiments.

Recommended implementation order: PersonaChat/ConvAI2 and Taskmaster-2, then
BST and Topical-Chat after their field/content reviews, followed by ABCD.
OASST1 and SGD are supplements; prose sources have lower priority for the
conversation-focused scope. This ordering is an engineering recommendation,
not a measured quality result or a corpus mixing ratio.

## Review validation

Upstream license/policy pages and dataset cards were inspected through web
access. Initial restricted `hf datasets info` requests failed to resolve the
host; authorized network access subsequently retrieved the publisher metadata
and pinned OASST1 revision. Acquisition, archive verification, reader tests and
measured bundle counts are recorded separately in the English guide/snapshot
and the repository testing record. This review alone does not establish archive
integrity or downstream model quality.
