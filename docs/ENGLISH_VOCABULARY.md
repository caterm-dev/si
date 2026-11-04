# English vocabulary maintenance

The current [base.csv](../Data/Vocabulary/english/base.csv) is converted from the pinned Wanxiang `dicts/en.dict.yaml`, preserving upstream integer weights without wordfreq normalization. It contains 72,784 supported English forms; with the preserved categories, the packaged resource contains 74,340 entries. The [import guide](../Data/Vocabulary/Wanxiang/README.md) records revision, full CC BY 4.0 data licensing, source checksums, exact conversion rules, exclusions and update commands.

The existing [movie.csv](../Data/Vocabulary/english/movie.csv) and [domain.csv](../Data/Vocabulary/english/domain.csv) retain text/readings with all weights set to 10. New local additions default to 10. Base owns overlapping weights and case-only spelling; other category entries remain available. Nonbase duplicates merge using maximum weight. The domain collection still contains 1,209 full hostnames and retains its independent Radar CC BY-NC 4.0 attribution. Neither categories nor their filenames introduce ranking bonuses or language modes.

English word/title keys retain SI's full-text alphabetic contract: lowercase output letters, omit spaces/punctuation and spell Arabic digits individually. Rime abbreviation codes are converted to full-text keys rather than adding a new abbreviation mode. Domains use exact lowercase ASCII text as reading, including dots/hyphens/digits, up to 253 characters. Outputs remain printable ASCII containing at least one letter, without surrounding whitespace. Nineteen unsupported upstream forms are explicitly listed in the conversion report. Case-only source variants use highest weight with first-source ties; missing weights remain zero with the existing scoring floor of one.

```sh
python3 scripts/wanxiang_dictionary.py fetch
python3 scripts/wanxiang_dictionary.py convert
python3 scripts/wanxiang_dictionary.py convert --check
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

Fetch is a separate explicit network operation. Conversion is offline and replaces both base CSVs, preserving category files. Normal CSV builds compile the editable collection without downloading or reimporting anything. Manual base edits are overwritten by a later conversion; maintain intentional additions as category data. See [the CSV contract](../Data/Vocabulary/README.md).

The shared resource unit is `si-wanxiang-weight-v1`, reference mass one, with unknown weight one. Base weights are upstream ranking values, not real occurrence counts or calibrated probabilities. The old retained-vocabulary normalization is no longer used. English casing and membership can change, including absent old forms; exact literal fallback remains available for every nonempty input.

English uses dictionary weights, spelling costs and language-transition costs without model context corrections. Builds and tests require no model staging. The dictionary migration does not establish ranking-quality improvement or host compatibility.

## Technology category

[technology.csv](../Data/Vocabulary/english/technology.csv) is an SI-authored selection of 164 common terms covering AI/machine learning, software development, hardware, networking, security and cloud computing. Examples include `AI`, `LLM`, `API`, `GPU`, `ChatGPT`, `Core ML`, `MLOps` and `cloud computing`. These additions use SI's GPLv3 license; no third-party wordlist is imported. The curation record in `Data/Vocabulary/meta.json` retains its scope, row count and CSV checksum.

Every category row uses editorial weight 10. Existing base entries still own their casing and weight: the category row `AI,ai,10` leaves the base `ai,ai,3078` effective. Lowercase `ai` therefore yields the English word `ai`, while uppercase `AI` yields `AI` through the existing case handling. This category introduces no abbreviation aliases or ranking bonus. Multiword readings omit spaces (`Core ML` → `coreml`); digits are spelled individually (`FP16` → `fponesix`).

The initial category adds 13 outputs absent from the other English CSVs; its remaining rows group existing terms without changing their effective weights or spelling. Rebuild the runtime dictionaries with the ordinary CSV build command after editing. Run `EnglishVocabularyTests` for exact technology output, case preservation, completions, disabled English and literal fallback. Automated checks do not establish live host compatibility.

## Historical bootstrap sources and attribution

[Data/Vocabulary/meta.json](../Data/Vocabulary/meta.json) indexes source-level provenance once, outside the rows. Old source wordlists, weighted snapshots, generated spelling tables, import configuration and the source frequency archive have been deleted. Their source-level metadata is preserved inline in `meta.json`. Licenses and attribution remain under `Data/English/licenses/` and `Data/Ranking/wordfreq-3.1.1/`. These records describe the previous base and retained category history; they are not the current base-word or frequency source. Preserve the applicable licenses and notices:

| Historical source | Purpose | Retained source forms |
| --- | --- | ---: |
| SCOWL / ESDB | Medium American-English selection | 61,172 |
| SI original | Original SI vocabulary | 638 |
| SI terminology | SI-authored additions | 22 |
| CSpell software tools | Tools, products and services | 572 |
| CSpell companies | Company and organization names | 718 |
| Rime Ice English extension | Names and abbreviations | 1,447 |

The sources overlap; the original bootstrap collection has 63,602 case-insensitively unique forms. That count is not a measured coverage score. The former bootstrap included an explicit `Gmail` correction. The new base follows Wanxiang spelling (currently `gmail`); it does not retain spelling corrections absent from that source.

SCOWL is pinned to `1e5b7d3a72f47a71da5d28686c1dd4b397178485`, CSpell to `5f051955183427037faba538a3e102a94951d003` and Rime Ice to `da1fbe602e38f26db846fa10120ee64c2b0324c0`. SCOWL's bootstrap used size 50, American spelling A, variant level 1, default category/POS class and no abbreviations. The external sources retained only ASCII alphabetic forms of 2–64 letters; SI's original `a` and `I` remain. Unsupported names were rejected as complete rows rather than transliterated or split into unrelated words. The inline bootstrap metadata preserves original source hashes, filtering and duplicate/casing policy.

Full redistribution notices are retained in [Data/English/licenses](../Data/English/licenses/), [EnglishVocabularyNotices.txt](../mac/SI/Resources/EnglishVocabularyNotices.txt) and [RankingNotices.txt](../mac/SI/Resources/RankingNotices.txt). SCOWL permits redistribution with notices, CSpell uses MIT, Rime Ice declares GPL-3.0-only, SI additions use GPLv3, and wordfreq-derived data retains CC-BY-SA-4.0 attribution. No installed system dictionary is copied.

The retired `scripts/vocabulary.py` / `scripts/vocabulary.sh` import tools and their snapshot-only tests have been removed. `scripts/ranking.py` now checks only the retained attribution and synthetic calibration; its wordfreq archive decoder/import is removed. The new Wanxiang converter does not reconstruct the former vocabulary from those retired sources. After source/license review, explicitly merge intended changes into category CSVs and update source-level metadata when needed.

Public dictionary changes can affect mixed segmentation and candidate ranking. Run the maintenance/core checks and relevant synthetic/manual checks from [TESTING.md](TESTING.md). Private phrases and app vocabulary are independent; these tools never inspect them. Do not infer production conversion quality or host compatibility from a source migration.
