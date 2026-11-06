# Chinese vocabulary categories

The original base contained 1,547,554 text/reading pairs imported from Wanxiang, with the documented SI editorial weight adjustments below. The seven earlier local categories retain their text/readings with every weight set to 10; new local entries default to 10. The separate reviewed corpus category uses explicit evidenced weights. See [Wanxiang conversion](../Wanxiang/README.md) for source pins, licensing, weights and reproduction. The ten other upstream Chinese dictionaries are separate CSV files named after the upstream files (602,516 rows); with the 266 corpus additions, the complete merged dictionary has 2,141,468 entries. Base weights take precedence, then imported category weights, then preserved local supplements. Ordering remains deterministic and category names add no ranking bonus.

| File | Rows | Scope |
| --- | ---: | --- |
| [base.csv](base.csv) | 1,501,057 | Wanxiang single-character, base and alternative-reading vocabulary, merged into toneless SI readings. |
| [geography.csv](geography.csv) | 18,141 | Geography and places: Administrative place names and geographical terms. |
| [organizations.csv](organizations.csv) | 4,312 | Organizations: Schools, universities, companies, associations, public agencies and cultural institutions. |
| [technology.csv](technology.csv) | 3,820 | Technology and engineering: Computing, software, networks, electronics, machinery and engineering terms. |
| [science.csv](science.csv) | 2,659 | Natural sciences: Mathematics, physics, chemistry, astronomy and biology terms. |
| [medicine.csv](medicine.csv) | 5,646 | Medicine and health: Medical specialties, diseases, medicines, treatments and related terms. |
| [movie.csv](movie.csv) | 810 | Movies: Identified film titles, cinema/festival terms and explicit movie-related vocabulary; includes the [2007–2026 title update](../MOVIES.md). |
| [game.csv](game.csv) | 741 | Games: Identified games/franchises, game-related vocabulary and esports. |
| [corpus.csv](corpus.csv) | 266 | Reviewed common/technical terms and complete names from six prepared Chinese corpus sources; [counts, exclusions and weight evidence](../Corpus/README.md). |

Before the Wanxiang base replacement, the October 28 movie update added 212 new effective identities and copies existing title rows into the movie category, bringing the merged Chinese dictionary to 953,837 entries. The table counts category rows; identical cross-category copies merge without changing weights. Existing category rows remain intact. See the [paired movie catalog and provenance](../MOVIES.md).

The former SI-authored `炼仙丹` base addition is now supplied by Wanxiang with weight 333. Historical counts and grouping rules below describe the earlier category split, not the current base or merged total.

## Phrase and verse grouping

[phrase/](phrase/README.md) now contains 46,497 clear base phrases and the
complete 335,208-row `shici.csv` collection. Original rows/readings/weights and
source-priority tiers are preserved; compilation includes both directories.
The effective dictionary remains 2,141,468 entries. See the phrase guide and
review record for conservative boundaries and source hashes.

## SI editorial weight adjustments

The [November 4 corpus review](../Corpus/README.md#weights) additionally records
eight bounded increases for `大连`, `抵挡`, `福建`, `茂名`, `韶关`, `湘潭`, `消极`
and `印尼`. Their token counts exceed conservative same-reading reference span
counts across dialogue, web and Wikipedia. Exact old/new values and source
evidence are in [corrections.csv](../Corpus/corrections.csv). Earlier explicit
user adjustments below are preserved. These are editorial values in the
existing weight unit, not occurrence counts or general accuracy measurements.

On October 31, 2026, the user requested increasing `上次` (`shang'ci`) from
the imported weight 21,766 to the SI editorial weight 40,000. Its text and reading
are unchanged. With the shared 1.05 frequency coefficient this adds about 0.922
bits to direct and prefix lexical scores and to a complete path that uses this
word. This is an editorial ranking adjustment, not a measured occurrence count.
The imported data retains its existing Wanxiang attribution and CC BY 4.0 terms.

On the same date, the user requested making `长的` the default first choice for
`changde`. Its `chang'de` weight increases from 14,363 to 20,000, above `唱的`
(18,096) and `常德` (14,365). Its separate `zhang'de` reading is unchanged.
This is an editorial ranking adjustment, not a measured occurrence count.

On November 4, 2026, the user requested ranking `语料` above `语聊` for
`yuliao`. Its `yu'liao` weight increases from 1,953 to 2,500, above `语聊`
(2,442) and below `预料` (3,036). This is an editorial ranking adjustment,
not a measured occurrence count.

On November 6, 2026, the user requested ranking `泰国` above `太过` for
`taiguo`. The `tai'guo` weight for `泰国` increases from 14,290 to 22,000.
`太过` keeps its weight of 20,909.

The base SHA-256 recorded in the import metadata/report identifies the original
pinned conversion; the generated runtime manifest records the current edited CSV
hash. Ordinary CSV builds preserve this edit. A fresh Wanxiang conversion replaces
manual base edits, and `wanxiang_dictionary.py convert --check` intentionally
reports this difference from the pinned conversion. Review/reapply these adjustments
when explicitly refreshing upstream data; no converter or source lock is changed.

## First-pass boundaries

This is a conservative first pass using recognizable domain terms, place/institution suffixes and selected unambiguous work titles from the existing vocabulary. It is not exhaustive semantic annotation. `base.csv` contains common vocabulary and the remaining unclassified entries; it is not a claim that every retained entry is common. Many personal names, idioms and ambiguous terms deliberately remain there for later review. Some domain-related phrases can remain in a broad category; semantic boundaries still need ongoing curation.

For the initial broad split, entries with at most two output characters stayed in base. Selected explicit movie/game titles have subsequently moved into their dedicated categories regardless of length or weight. For longer outputs, if any reading of that exact output has weight at least 20,000, all its readings stay in base, except selected clear work titles. This is an editing heuristic applied once, not a new frequency scale, a runtime threshold or a guarantee of common usage. Less frequent entries only move when a recognizable domain cue is present. All pronunciations of an output move together.

The grouping was sampled and refined to avoid obvious substring collisions: `公共知识分子`, `更好地理解`, `优化学校`, `约旦哈希姆` and `改革进程` remain in base. Manual review also keeps verbal `学会` phrases and financial/market `入市`/`集市` phrases out of organization/place groups; `数据集市` is assigned to technology, while `辛集市` and `攀枝花市` remain geographical. Film titles such as `流浪地球` and `星际穿越` are grouped under movie; games such as `黑神话悟空`, `原神` and `王者荣耀` are grouped under game. Other cultural/sports terms retain their existing category. Bare names with another clear primary meaning or an ambiguous medium, such as `哪吒`, `三体`, `哈利波特`, `传奇` and `崩坏`, retain their previous placement. Film titles such as `模仿游戏` are not assigned to games merely because their names contain `游戏`. This refinement does not claim complete film/game coverage. No additional upstream data or dictionary rows were introduced.

## Continue editing

Edit these CSVs directly. Move a complete text/reading row to another category when its placement is clearer; keep its exact text, reading and weight. No ordering ID or per-row source metadata is required. The initial grouping does not rerun during a build or override subsequent manual moves. To add a finer category later, create another flat CSV with the same `text,reading,weight` header. See the shared [CSV contract](../README.md) for duplicate and weight rules.

After editing, build/check from the repository root:

```sh
python3 scripts/csv_dictionary.py build --language chinese
python3 scripts/csv_dictionary.py build --check
```

The historical first split preserved the exact 953,625-row multiset, contains no duplicate identities and keeps all readings of each output in one file. Category-only moves preserve stored rows and candidate tie order. The later movie update expands vocabulary separately; neither establishes production input quality.
