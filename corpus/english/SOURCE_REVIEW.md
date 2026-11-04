# English corpus source review

Reviewed on **2026-11-04**. This is a source-selection assessment, not a source
lock or an acquired corpus. English fetching/cleaning is not implemented yet.
No archives have been downloaded, no English counts have been measured, and no
training or changes to runtime dictionaries are implied.

## Recommended initial sources

The initial collection should cover general prose, technical writing and
conversation. The recommendations below apply to the specified upstream text,
subject to its notices and any file-specific exceptions. Public availability
alone does not establish permission to reuse content.

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

Recommended implementation order: Kubernetes and Rust for Markdown extraction,
Wikipedia for general prose, OASST1 for conversation, then Python and MDN with
their additional format/license handling. This ordering is an engineering
recommendation, not a measured quality result or a corpus mixing ratio.

## Review validation

Upstream license/policy pages and dataset cards were inspected through web
access. Local `hf datasets info` metadata requests failed because the execution
environment could not resolve the host; no Hub revision or archive integrity is
claimed here. English download/cleaning tests will belong to implementation.
This documentation-only review does not require an app build or installation.
