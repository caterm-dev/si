# Chinese vocabulary maintenance

SI merges selected annotated [Rime Ice](https://github.com/iDvel/rime-ice) data with its original Chinese entries and local additions. The existing decoder and English provider continue to share one candidate engine. Rime's runtime, configuration, language switches, Lua extensions, automatic pronunciation generation and language models are not imported.

## Included data and selection

The initial import pins Rime Ice commit `da1fbe602e38f26db846fa10120ee64c2b0324c0`.

| Source | Initial entries | Selection |
| --- | ---: | --- |
| `rime-ice-characters` | 8,757 | Explicit readings in `cn_dicts/8105.dict.yaml`, including its additions and polyphonic readings |
| `rime-ice-base` | 76,827 | Explicit readings in `cn_dicts/base.dict.yaml` with upstream weight at least 10,000 |
| `si-original` | 979 | Every original SI text/reading and its editorial score |
| `si-terms` | 3 | Original SI additions for vocabulary maintenance and mixed input |

The initial merged result contains **85,596 text/reading pairs**, representing 84,880 distinct texts. A polyphonic word can have several entries. Current counts and hashes are in [the generated summary](../Data/Chinese/generated/summary.json); use `stats` after updates.

The first default includes a weight-selected part of the base dictionary, not all Rime Ice data. The upstream base has over 540,000 annotated entries, and `ext` adds over 330,000 more. Their full import has not been validated for SI's startup, memory, candidate quality and key-event path. The cutoff is an explicit, editable import setting, not an independent measure of word quality or a trained language model. Some upstream weights are editorial. Change `minimum_weight` and count guards deliberately and rerun measurements before adopting a larger selection.

`ext.dict.yaml` and the optional 41,448-character dictionary are not currently registered. `tencent.dict.yaml` contains unannotated text/weight rows; Rime normally derives their readings, which this adapter deliberately does not guess. English dictionaries, user phrases, Emoji and schema files are also excluded.

Rime Ice declares GPL-3.0-only, matching SI's GPLv3 distribution. Its complete license and the exact selected files' original headers are retained in [licenses](../Data/Chinese/licenses/) and [attributions](../Data/Chinese/attributions/). Those headers list their source materials, including THUOCL, the Tencent word-vector vocabulary, reference dictionaries, Wiktionary's character table and the BLCU character-frequency table. THUOCL's MIT notice is also retained. These notices remain part of the generated `ChineseVocabularyNotices.txt` app resource. This imports the Rime Ice-maintained dictionary tables under their declared license, not their upstream corpora, vectors or software. New sources still need origin and license review under [CONTRIBUTING.md](../CONTRIBUTING.md).

## Commands

Use the shared vocabulary command with the language option **before** its subcommand. Existing commands without this option continue to maintain English.

```sh
./scripts/vocabulary.sh --language chinese stats
./scripts/vocabulary.sh --language chinese explain 字幕
./scripts/vocabulary.sh --language chinese build
./scripts/vocabulary.sh --language chinese build --check
./scripts/vocabulary.sh --language chinese audit --report .build/vocabulary-chinese-audit.json
# Review the upstream revision, then refresh the entire registered Rime Ice group:
./scripts/vocabulary.sh --language chinese refresh rime-ice --revision FULL_40_CHARACTER_COMMIT_SHA
# Explicitly import the tracked branch's latest revision:
./scripts/vocabulary.sh --language chinese refresh rime-ice --latest
# Reproduce the currently pinned imports:
./scripts/vocabulary.sh --language chinese refresh rime-ice
```

A group refresh resolves one latest revision for both Rime Ice tables and stages their snapshots, license, headers, lock and merged outputs before validation/writes. A failed download, malformed table, empty/out-of-bounds result, checksum failure or unaccepted license change leaves existing files intact. A specific source ID can also be refreshed on its own. License changes require inspection and the explicit `--accept-license-change` option; accepting a changed notice does not establish its suitability.

`Data/Chinese/sources.json` registers sources, priorities, selection and score mapping. `sources.lock.json` pins revisions, upstream download hashes, normalized snapshot hashes, license/header hashes and filtering counts. Sources, locks, generated outputs and notices must be reviewed together. The monthly vocabulary workflow audits both English and Chinese and retains comparison links and JSON reports. It does not update repository files, install SI, or read personal dictionaries. The workflow must reach the default branch with Actions enabled before its schedule applies.

## Add, correct or exclude entries

Edit [si-terms.tsv](../Data/Chinese/sources/si-terms.tsv) for original local additions. Rows contain Han text, space-separated Pinyin and an editorial score, separated by actual Tab characters:

```text
字幕	zi mu	100
词库维护	ci ku wei hu	100
```

Use `v` for ü; explicit `ü` and `u:` spellings normalize to the same lookup reading. The text is preserved exactly. There must be one syllable per Han character, no tone numbers, no empty syllables and at most 64 normalized letters. Unsupported text/reading pairs in upstream tables are counted and filtered, never silently auto-pronounced. Invalid or duplicate local entries fail validation. Polyphonic readings remain distinct.

Use [overrides.json](../Data/Chinese/overrides.json) for lasting changes to an upstream text/reading pair rather than editing its snapshot. This synthetic example excludes one reading and replaces another:

```json
{
  "schema_version": 1,
  "rules": [
    {"text": "示例", "reading": "shi lie", "action": "exclude", "reason": "Incorrect reading"},
    {"text": "词库", "reading": "ci gu", "action": "replace", "reason": "Correct pronunciation",
     "replacement": {"text": "词库", "reading": "ci ku", "score": 100}}
  ]
}
```

Rules require a reason and a unique original text/reading. Exclusions run last as well, so replacements cannot reintroduce an excluded pair. Inactive rules are reported and retained for future upstream versions. The generated provenance table records every contributing source. Source priority resolves duplicate pairs; SI originals retain their original scores, and local additions/overrides win. Personal phrases and learning data are separate and unchanged.

Imported weights map to a bounded score: `min(score_max, score_min + decimal_magnitude(max(1, weight)))`, currently 92–99. Exact English matches remain 110; SI original scores are preserved. The mapping is an editorial ranking input, not a probability. The full spelling, initials, mixed full/initial readings and incomplete final syllable continue to use the shared bounded decoder.

## Runtime and validation

The generated Swift data is compiled into both the package and app. The app does not download or parse external vocabulary files. Decoder initialization groups words sharing a syllable sequence, shares their abbreviation/boundary metadata and stores IDs in exact indexes. Full-spelling completion uses binary-search ranges rather than a copy of each entry under every prefix. The default engine prepares the shared decoder on construction.

Complete and incomplete terminal paths have separate bounded pools of 12 base and up to 12 personalized alternatives per existing language/verbatim/last-language state. Completion edges always finish the input, so intermediate continuation budgets do not grow. Large terminal batches are compacted with a bounded ordered selection after applying actual scores and eligible learning. Direct lexical/personal matches and literal fallback remain independently available; the merged result has no global cap. Prefix presentation still retains two distinct results per language combination and consumed span.

A Chinese abbreviation that stops inside an exact English word cannot gain token-learning bonuses for that split path. Explicit whole-input choices can still prefer alternative segmentations. This extends the existing English boundary safeguard to new Chinese abbreviation matches without hiding them.

```sh
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/vocabulary.sh build --check
./scripts/vocabulary.sh --language chinese build --check
./scripts/test.sh
./scripts/build.sh
./scripts/benchmark.sh --resources
```

The tests cover imports, weighting, polyphony, normalization, persistent overrides, source/hash/license checks, failed group updates, original-entry preservation, mixed input, completion crowding and independent exhaustive terminal ranking. Vocabulary changes can still alter segmentation and which constructed paths survive the bounded search. Follow [manual typing checks](TESTING.md) for `zimu`, `shujuku`, `rengongzhineng`, `zimusubtitle`, `nihaotitle`, language settings, broad-prefix paging, focus and shortcuts. See [measured verification](VERIFICATION.md) for results and remaining limits. No command commits, publishes, installs or changes enabled input sources.
