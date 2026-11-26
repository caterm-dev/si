# Selected character-model training sources

This bundle contains the step-11,000 checkpoint selected from the first
20-million-target stage of small-chat-unused-v3. It inherits weights from
small-chat-v2 and small-character-v1. The full checkpoint lineage is in
manifest.json. The root source-lock.json records this continuation; inherited
source locks, notices and licenses are under metadata/lineage/.

Inherited notices:

- [small-character-v1](metadata/lineage/small-character-v1/NOTICE.md)
- [small-chat-v2](metadata/lineage/small-chat-v2/NOTICE.md)

Per-source terms and unresolved declarations remain as recorded in the
copied documents. These notices assign no blanket license to model weights.

## Current continuation

# Actual corpus sources selected for this dataset

The source-lock.json and manifest.json list the sources actually retained.
Full source license/card documents are copied beside this notice.

Modifications: markup/code removal, OpenCC t2s conversion, control-character
replacement, exact-document deduplication and cross-split long-paragraph filtering.
Punctuation, English word spaces and paragraph boundaries remain in document text.
Original source rights and any ShareAlike conditions remain applicable.

This dataset does not assign a blanket license to future trained weights.

- lccc: LCCC-base training dialogues, MIT; https://huggingface.co/datasets/silver/lccc; revision 5bd582fa28cd7143f2f9c852e08e23089d677c44.
- chinese-chatbot-corpus: chinese-chatbot-corpus, see per-dataset attribution; see source-lock.json; revision b673560147403c5a50c73863baed49f60d9bf69b700f830b448f3c575c665c34.
- dialogue: dialogue, see per-dataset attribution; see source-lock.json; revision 289c7f494f875c01bfdd09bf71f07a769cc7064529cc2101af1184eda1d1873b.
