# Wanxiang base dictionary conversion

SI's Chinese and English base CSVs are converted from
[amzxyz/rime-wanxiang-data](https://github.com/amzxyz/rime-wanxiang-data), revision
`adfa047c339627737f0a4c75674a8042c1ef7f72` on branch `wanxiang`.
The human user explicitly requested this source replacement. SI's converter is
independently written Python using the standard library; no upstream program,
Rime runtime, language model or tool dependency is imported.

## Scope and license

| Source | Destination | Selection |
| --- | --- | --- |
| `dicts/zi.dict.yaml` | `chinese/base.csv` | Simplified single-character readings |
| `dicts/jichu.dict.yaml` | `chinese/base.csv` | Simplified base vocabulary |
| `dicts/duoyin.dict.yaml` | `chinese/base.csv` | Alternative readings and compatibility phrases |
| `dicts/en.dict.yaml` | `english/base.csv` | English words, names and explicit phrases |

All other normal simplified Chinese dictionaries retain separate SI categories:
`diming.csv`, `fangyan.csv`, `huaxue.csv`,
`mingren.csv`, `shici.csv`, `taifeng.csv`,
`wuzhong.csv`, `yaopin.csv`, `yiren.csv` and
`yixue.csv`. Each maps directly to the same-named upstream dictionary,
using the upstream stem, without an added prefix. These ten files contain 602,516 rows in total. Their filenames now match the upstream stems (`diming.csv`, for example); source ownership is tracked in metadata rather than inferred from a filename prefix.

The resulting bases contain 1,547,554 Chinese text/reading pairs and 72,783
supported English forms. The initial migration and its local supplements are
documented in the [verification record](VERIFICATION.md).
The upstream base alone has about 1.49 million rows: replacing the source does
not imply a smaller dictionary. Upstream professional, poetry, name/place and
dialect dictionaries are imported
as separate categories. Abbreviation, T9 abbreviation, mixed-language and
erroneous-reading dictionaries are excluded.
The nine local category CSVs retain text/readings and use weight 10, also the default for newly added local words; their current hashes
are recorded in [conversion-report.json](conversion-report.json).

The original data is CC BY 4.0, attributed to amzxyz and contributors. The full
[LICENSE](LICENSE), [LICENSE-SCOPE.md](LICENSE-SCOPE.md) and
[upstream NOTICE](NOTICE.md) are retained. The scope document expressly permits
original dictionary data and does not grant a general license to upstream
program code. SI imports data only. Both packaged resource directories include
`Wanxiang-NOTICE.txt` and `Wanxiang-CC-BY-4.0.txt`; SI's application and conversion
code remain GPLv3. Retained category data keeps its earlier per-source licenses,
including the Radar domain collection's separate CC BY-NC 4.0 terms. Local category CSV weights were reset to 10 on October 29; imported source weights were not rescaled.

## Exact conversion rules

- Preserve output text bytes, except that unsupported entries are explicitly
  excluded. Never normalize committed Unicode output.
- Remove Chinese tone marks from readings and map ü to `v`, retaining apostrophe
  syllable separators in SI. Distinct readings remain separate. When tones
  collapse to the same text/reading identity, retain the maximum source weight.
- Preserve every supplied integer weight without scaling, normalization,
  logarithms or conversion through wordfreq. Both unknown weights are one.
  Upstream already transforms its ranking weights; they are not raw usage counts
  or calibrated probabilities.
- Keep absent weights as zero: 355 Chinese rows and 226 English rows in the pinned
  sources omit them. The runtime's existing floor treats zero as one for scoring.
- Seventy-three source weights (`jichu`: 15, `shici`: 1, `yaopin`: 57) contain
  an integer followed by `N` or `s`.
  Use the integer prefix, matching Rime's `std::stod` parsing, and count these
  conversions separately. Reject other malformed, negative or overflowing weights.
- English uses SI's existing full-text alphabetic key: lowercase letters, remove
  output spaces/punctuation, spell digits individually. Rime abbreviation and
  apostrophe codes are not introduced as a new SI typing mode. The report counts
  converted source codes. Full domains retain their existing literal keys.
- Merge English case-only variants using the highest source weight. Equal weights
  retain the first spelling in the pinned source; never depend on filesystem order.
- Exclude private-use outputs and English forms outside the existing printable
  ASCII/full-key contract. All 19 excluded English forms, source lines and reasons
  are listed in the report; accented forms are not silently transliterated.
- Exclude `wolai` and its case variants from the English import because the
  spelling represents the Pinyin `wǒ lái` (我来). The report records this editorial
  exclusion separately from unsupported forms.
- Emit deterministic UTF-8 CSV ordered by reading bytes, then exact text bytes.
  The runtime compiler assigns IDs from the same content order.

`meta.json` selects `category_overlap: "base"`. A base identity owns its source
weight, even when a preserved category copy has a higher weight. English base
spelling also shadows case-only category copies. The `upstream_categories`
metadata identifies the imported categories; their
weights override legacy category copies absent from base. Duplicates among
imported categories use maximum weight. Other preserved category identities
remain available, with maximum-weight merging among those local additions. This deliberate
precedence prevents preserved historical category weights from undoing the new
base frequencies, while leaving the category files unchanged.

The resource contract is now `si-wanxiang-weight-v1`, with `reference_mass=1`.
Older relative-frequency resources fail closed. Source equality is not Rime/Wanxiang decoder
parity or evidence of improved ranking quality.

## Reproduce and verify

From the repository root:

```sh
# Explicit network action; verifies pinned size and SHA-256 before caching:
python3 scripts/wanxiang_dictionary.py fetch
# Offline conversion, validating all destinations before replacing files:
python3 scripts/wanxiang_dictionary.py convert
python3 scripts/wanxiang_dictionary.py convert --check
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
python3 scripts/msime_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

The default source cache is `.build/vocabulary/wanxiang/<revision>/dicts/`.
Use `--source-dir /absolute/path/to/source-root` with `fetch` or `convert` to
select an existing download/check-out containing `dicts/`. Downloads are never
triggered by conversion, CSV compilation, app builds or typing. A corrupt cached
file is rejected rather than silently replaced.

`convert --check` compares both base CSVs, all ten imported categories, metadata
and the report
without modifying them. Conversion validates the source checksums and the whole
CSV collection, including category casing conflicts, before publication; an
ordinary publication exception restores the previous generated CSV/metadata bytes.
This does not claim filesystem transaction guarantees across power loss. Neither
conversion nor compilation reads private phrases, learning files or user input.

## Adopt a newer upstream revision

Review the intended commit, selected dictionary files, data licensing and format
changes. Update [upstream.lock.json](upstream.lock.json) with the exact 40-character
revision, source sizes/SHA-256 values and retained license-document hashes.
Retain changed upstream license/scope/notice files and update the packaged notices
in both resource directories. Then run the explicit fetch/convert/build/check
commands above and review the vocabulary, weights, casing and exclusions diff.

The pinned English source omits the standalone words `a` and `ma` and uses
lowercase `gmail`. SI follows that membership/casing; it does not restore the
previous English list implicitly. Exact original input remains available even
when no dictionary word matches.

The current Chinese base includes the [documented SI editorial weight adjustments](../chinese/README.md#si-editorial-weight-adjustments)
for `上次`: 21,766 to 40,000, and `长的` (`chang'de`): 14,363 to 20,000. This does not alter the pinned source or conversion
rules; a conversion check reports the intentional difference, and reimport
overwrites it unless the adjustment is explicitly reapplied.

Reimport replaces manual base and imported category edits. Keep intentional SI additions in separate
category CSVs; an overlapping base identity remains authoritative. Category edits
change the preserved-category hashes in a subsequent conversion report. Removed
upstream categories are deleted only if their last generated bytes are unchanged;
local edits block that retirement rather than being silently discarded. Do not
derive a source lock from private data or drop old attribution that still applies
to retained category entries.

Use synthetic inputs to inspect language filtering, exact original fallback,
complete and prefix commits, English casing/segmentation and Chinese/mixed
ranking. A successful automated run does not establish host compatibility;
follow [the native checks](../../../docs/TESTING.md) before claiming it.

See the [October 29 verification record](VERIFICATION.md) for checks actually run,
the source-specific regression updates and remaining limitations.

## Maintained phrase layout

The November 5 conservative [phrase grouping](../chinese/phrase/README.md) moves clear
base combinations to `chinese/phrase/base.csv` and the complete poetry category to
`chinese/phrase/shici.csv`. Original basenames retain their compilation priority across
both directories. Conversion totals above describe the original unsplit import;
ordinary CSV compilation uses the maintained layout. Explicit upstream conversion
still regenerates original import locations: review/reapply the phrase grouping
and existing editorial edits when deliberately refreshing upstream data.
