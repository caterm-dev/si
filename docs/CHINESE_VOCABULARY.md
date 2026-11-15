# Chinese vocabulary maintenance

Edit the flat category CSVs in [Data/Chinese](../Data/Chinese/). Each row
has `text,reading,weight`. Use lowercase Pinyin with apostrophes between
syllables and `v` for ü in the dictionary key. Keep the exact output bytes
and supply an explicit nonnegative integer count. Polyphonic readings
remain separate entries. Repeating an exact text/reading pair across
categories adds its counts.

To validate both languages with the standalone Rust compiler, build to a new
path. Debug and Release package the prepared snapshots under `target/si-data/`.

```sh
si_vocab_check="$(mktemp -d)"
./scripts/si-lexicon-build.sh "$si_vocab_check/main.silex"
cargo run --locked -p si-cli -- check-resources "$si_vocab_check/main.silex"
```

The base derives from pinned Wanxiang data and the coarse HanLP vocabulary
migration. Wanxiang imports removed tones and merged tone-collapsed
source identities before publication. Current compilation sums the counts
present in the maintained CSVs. The migration requires an explicit
historical source directory for reproduction. [Migration workflow](../Data/Chinese/README.md)

Keep source terms and notices with any vocabulary contribution.
Current Wanxiang attribution and the legacy MSIME/Rime Ice notices for
retained data are packaged with the dictionary. Corpus imports and word
discovery operate on separately selected local Rust snapshots. [Packaged notices](../mac/SI/Core/Resources/Chinese/) · [Rust resource workflow](ARCHITECTURE.md#rust-resource-workflow)
