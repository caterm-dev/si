# Chinese phrases and verse

This directory groups phrase/utterance and poetry CSVs under the Chinese
language directory. Word CSVs remain in the parent `../` directory. CSVs use the same `text,reading,weight` contract. All files here
remain part of the Chinese input-method dictionary; no ranking bonus, new
language mode or private personal-phrase storage is implied.

| File | Rows | Scope |
| --- | ---: | --- |
| [base.csv](base.csv) | 46,497 | Clear grammatical combinations moved from the maintained base. |
| [shici.csv](shici.csv) | 335,208 | The complete existing poetry/verse source, moved without changing its bytes. |

The user requested a conservative split on November 5, 2026. Examples include
`根据材料`, `根据不同的需求`, `根据大数据分析` and `更好地理解`. Recognizable
idioms, named entities and complete domain terms stay in the word collection;
ambiguous entries are retained. This is a first semantic curation pass, not a
claim that every remaining base entry is a single word. The verse source also
contains short forms, titles and fixed expressions; its complete grouping does
not label every row as a grammatical sentence.

An explicit one-time scan used grammatical frames (prepositions/conditions,
modal and adverbial combinations, subject/predicate, possessive/attributive 的,
adverbial 地, aspect and time clauses). Independent previously collected HanLP
word observations and existing curated name/domain categories served as
conservative lexical guards, with reviewed exceptions. No length-only rule
classifies ordinary vocabulary. No neural model, network, new data import or
classification step runs during normal compilation.

[review.json](review.json) records the rule expressions, source/reference hashes,
reviewed exceptions, counts, output hashes and effective-dictionary fingerprint.
Each original row, spelling, reading and weight is preserved. Basenames retain
source precedence: `chinese/phrase/base.csv` belongs to the same base tier as
`chinese/base.csv`; `chinese/phrase/shici.csv` retains its upstream category tier. This
prevents a lower/zero base weight from being replaced by another category copy.
All 2,141,468 effective Chinese entries, including generated row IDs and tie
order, remain unchanged after compilation.

Edit these CSVs directly. Additional local phrase files may use a different flat
basename, such as `conversation.csv`; they default to local weight 10. Use the
same original basename when moving entries from an authoritative source so its
priority remains intact. Keep the word-side `chinese/base.csv` file. Original
source notices and licensing remain under the vocabulary metadata/Wanxiang
records. A new upstream conversion regenerates its original unsplit files;
review/reapply grouping and editorial edits explicitly after an upstream refresh.
Ordinary builds never reimport upstream data or reclassify text.

```sh
python3 scripts/csv_dictionary.py build --language chinese
python3 scripts/csv_dictionary.py build --check --language chinese
```
