# Chinese corpus attribution

SI's preparation tools are GPL-3.0-only. The downloaded text and derived text
files retain their own data terms; SI's software license does not relicense them.
The first batch follows the acquisition/cleaning/reading-table organization of
[chinese-ime-lm](https://github.com/metasequoiaime/chinese-ime-lm/tree/154eb5c59a5ad9b0c93a48b05dc7cd143601d18a/corpus).
SI's scripts are independently written; no upstream implementation is copied.

Exact revisions, archive sizes, SHA-256 values, URLs and retained license/card
checksums are in [sources.lock.json](sources.lock.json). Each prepared bundle
copies that lock, this notice and the complete retained license documents.
Every output line has an aligned origin in `origins.jsonl`: an archive-relative
document path, an LCCC row/turn, an mC4 row, or a Wikipedia page/revision URL. Resolve document paths against
the pinned repository revision and its contributor history for attribution.

| Source | Attribution and terms | Selected scope |
| --- | --- | --- |
| LCCC | Yida Wang, Pei Ke, Yinhe Zheng, Kaili Huang, Yong Jiang, Xiaoyan Zhu and Minlie Huang, *A Large-Scale Chinese Short-Text Conversation Dataset*, NLPCC 2020 ([paper](https://arxiv.org/abs/2008.03946)); [CDial-GPT](https://github.com/thu-coai/CDial-GPT), Copyright (c) 2020 lemon234071, MIT. The `silver/lccc` mirror declares MIT in its dataset metadata; its licensing-details section remains incomplete. The original MIT notice and the mirror's full card are retained. | `lccc_base_train.jsonl.gz` only; official validation/test files are excluded. |
| mC4 Chinese | Allen Institute for AI / Google Research, multilingual C4; Xue et al., *mT5: A Massively Multilingual Pre-trained Text-to-Text Transformer* ([paper](https://arxiv.org/abs/2010.11934)); [dataset card](https://huggingface.co/datasets/allenai/c4). ODC Attribution 1.0 covers database rights, with required source attribution. Rights in individual web documents remain with their owners; the database license is not a blanket copyright grant for all pages. | Chinese training shard `00000` of `01024`; not all Chinese mC4. |
| Kubernetes | The Kubernetes Authors and documentation contributors, [kubernetes/website](https://github.com/kubernetes/website), CC BY 4.0. Retain attribution, license and an indication of modifications. | `content/zh-cn/`, Markdown/HTML files. |
| TensorFlow | Copyright 2020 The TensorFlow Authors and translation contributors, [tensorflow/docs-l10n](https://github.com/tensorflow/docs-l10n), Apache 2.0 as declared in this repository's retained LICENSE. Individual page notices remain applicable; this is the translation repository's source license, not a claim about all tensorflow.org content. | `site/zh-cn/`, Markdown/HTML files; notebooks and code are excluded. |
| MDN | Mozilla and MDN contributors, [mdn/translated-content](https://github.com/mdn/translated-content), CC BY-SA 2.5 for documentation, as stated in the retained LICENSE.md. Derived text retains ShareAlike obligations and stays separate from the other sources. | `files/zh-cn/`, Markdown/HTML files; code samples are excluded. |
| Chinese Wikipedia | Wikipedia contributors, [Chinese Wikipedia](https://zh.wikipedia.org/), CC BY-SA 4.0 as described by the [official dump terms](https://dumps.wikimedia.org/legal.html). The full CC BY-SA 4.0 legal code and dump terms are retained. Page/revision URLs identify each fragment's first source; the linked page history identifies contributors. Derived text retains attribution, modification notices and ShareAlike obligations. Individual exceptions described in the dump terms remain applicable. | Complete dated `pages-articles.xml.bz2` archive, retaining original simplified/traditional text and current revisions. Cleaned text selects namespace 0 wikitext pages, excluding redirects, templates, tables, references and code. Revision history, media binaries and talk pages are not training text. |

Modifications: SI strips documentation markup/code, restores LCCC token spaces,
converts traditional Chinese to simplified with OpenCC `t2s`, splits at all
non-Han boundaries, keeps 4–96-character fragments, and removes exact duplicate
fragments within each source. Character limits select a deterministic prefix
of each source's unique output. No source is relabeled as SI-authored text.
For Wikipedia, cleaning also removes nested wikitext templates/tables,
nonprose namespaces, redirects, references/media links and code blocks without
expanding templates. Display text from ordinary internal/external links remains.
The untouched raw dump and official checksum/completion metadata are retained
separately. Wikipedia stays in its own ShareAlike source directory.

The preparation dependency `opencc-python-reimplemented` 0.1.7 is Apache-2.0
([source](https://github.com/yichen0831/opencc-python)); its package notice/license
remains installed in the isolated environment. It is not linked into SI.
The lexical reading exports use existing SI/Wanxiang data and retain their
separate provenance and notices from `Data/Vocabulary`; dictionary weights are
ranking values, not observed sentence counts.

This collection is offline research material. No prepared corpus or model is
published or bundled into the input method by these tools. A future release
must carry the terms of the actual selected sources; this preparation does not
decide the licensing of future model weights. The sources are public corpora,
not a guarantee of privacy filtering, correctness, balanced sampling or absence
of benchmark overlap. Personal phrases, app vocabulary, typing histories,
documents and clipboard data are never inputs.
